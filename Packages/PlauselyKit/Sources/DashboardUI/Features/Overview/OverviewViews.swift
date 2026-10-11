import AnalyticsCore
import Charts
import SwiftUI

/// Deterministic overview/series loaders for UI tests and previews. Numbers
/// mirror the CE 3.2.1 fixture `top-stats.day.json` exactly (1600/1600/1400/
/// 0.88/88%/0s); production loaders arrive with the client-wiring follow-on.
public enum MockOverviewProviders {
    public static var overview: ReportModel<Overview>.Loader {
        { query, today in
            // Comparison mode synthesizes server-shaped previous values and
            // deltas (mirroring the upstream Google 2-vs-0 → +100% shape),
            // so badges, colors, and previous/comparison rows render in
            // mock mode exactly like live ones.
            let comparing = query.comparison != .off
            func stat(
                _ metric: MetricID, _ name: String, _ value: MetricValue,
                change: Int? = nil, comparison: MetricValue? = nil
            ) -> TopStat {
                TopStat(
                    metric: metric, name: name, value: value,
                    comparisonValue: comparing ? comparison : nil,
                    change: comparing ? change : nil
                )
            }
            let stats = [
                stat(.visitors, "Unique visitors", .count(1600), change: 12, comparison: .count(1428)),
                stat(.visits, "Total visits", .count(1600), change: -5, comparison: .count(1680)),
                stat(.pageviews, "Total pageviews", .count(1400), change: 0, comparison: .count(1400)),
                stat(
                    .viewsPerVisit, "Views per visit", .decimal(Decimal(string: "0.88")!),
                    change: 3, comparison: .decimal(Decimal(string: "0.85")!)
                ),
                stat(.bounceRate, "Bounce rate", .count(88), change: -2, comparison: .count(90)),
                stat(.visitDuration, "Visit duration", .count(0), change: 0, comparison: .count(0)),
            ]
            let id = try QueryID.compute(for: query, today: today)
            return ReportEnvelope(queryID: id, value: Overview(stats: stats), retrievedAt: today)
        }
    }

    public static var series: ReportModel<TimeSeries>.Loader {
        { query, today in
            let labels = ["00:00", "03:00", "06:00", "09:00", "12:00", "15:00", "18:00", "21:00"]
            let base: Int64
            switch query.selectedMetric {
            case .visitors: base = 12
            case .visits: base = 14
            case .pageviews: base = 20
            case .viewsPerVisit: base = 1
            case .bounceRate: base = 80
            case .visitDuration: base = 30
            default: base = 5
            }
            let comparison: [MetricValue?]? =
                query.comparison == .off
                ? nil
                : labels.indices.map { .count(base * Int64($0) + 3) }
            let id = try QueryID.compute(for: query, today: today)
            return ReportEnvelope(
                queryID: id,
                value: TimeSeries(
                    metric: query.selectedMetric,
                    labels: labels,
                    plot: labels.indices.map { index in
                        index == 2 ? nil : .count(base * Int64(index + 1))
                    },
                    comparisonPlot: comparison
                ),
                retrievedAt: today
            )
        }
    }
}

/// Overview section: headline cards plus the selectable-metric series chart.
/// Loads through the model's independent lifecycles; every state (loading,
/// stale, error with retry, empty) renders through the shared ReportStateView.
public struct OverviewContentView: View {
    private let query: DashboardQuery
    @Bindable private var model: OverviewModel

    public init(query: DashboardQuery, model: OverviewModel) {
        self.query = query
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReportStateView(state: model.dashboard.overview.state, onRetry: {
                Task { await model.refresh() }
            }, content: {
                TopStatsGrid(overview: $0.value, warnings: $0.warnings)
            })
            MetricPickerView(model: model)
            ReportStateView(state: model.dashboard.series.state, onRetry: {
                Task { await model.refresh() }
            }, content: {
                SeriesChartView(series: $0.value, metric: model.selectedMetric, period: query.period, periodDate: query.periodDate, timeZone: query.timeZone)
            })
        }
        .task(id: query) {
            await model.reload(query: query)
        }
    }
}

/// Headline cards in dashboard order. Values render server aggregates only;
/// no client-side math exists on this path by construction.
public struct TopStatsGrid: View {
    private let overview: Overview
    private let warnings: [ReportWarning]
    private let formatter = MetricFormatter()

    public init(overview: Overview, warnings: [ReportWarning] = []) {
        self.overview = overview
        self.warnings = warnings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("overview-warning-\(index)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(overview.stats, id: \.metric) { stat in
                    statRow(stat)
                }
            }
        }
    }

    /// Full-width stat row: every tile shares one rail and every text block
    /// shares another, on both platforms and at any width.
    private func statRow(_ stat: TopStat) -> some View {
        HStack(spacing: 10) {
            MetricTile(metric: stat.metric)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatter.string(for: stat.value, as: stat.metric))
                    .font(.title3)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: stat.value)
                    .accessibilityIdentifier("overview-value-\(stat.metric.rawValue)")
                if let change = changeText(stat.change) {
                    Text(change)
                        .font(.caption)
                        .foregroundStyle(changeDirectionColor(stat.change))
                        .accessibilityIdentifier("overview-change-\(stat.metric.rawValue)")
                }
                if let comparison = stat.comparisonValue {
                    Text("vs \(formatter.string(for: comparison, as: stat.metric))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("overview-comparison-\(stat.metric.rawValue)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-stat-\(stat.metric.rawValue)")
    }
}

/// Series metric picker (MET-01 traffic set). Switching reloads the series
/// only; the overview cards keep their independent lifecycle.
public struct MetricPickerView: View {
    @Bindable private var model: OverviewModel

    public init(model: OverviewModel) {
        self.model = model
    }

    public var body: some View {
        Menu {
            ForEach(OverviewModel.chartMetrics, id: \.self) { metric in
                Button(MetricID.descriptor(for: metric).displayName) {
                    Task { await model.reselect(metric) }
                }
                .accessibilityIdentifier("metric-option-\(metric.rawValue)")
            }
        } label: {
            HStack(spacing: 6) {
                Label(MetricID.descriptor(for: model.selectedMetric).displayName, systemImage: "chart.line.uptrend.xyaxis")
                #if os(macOS)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                #endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityIdentifier("metric-picker")
        .sensoryFeedback(.selection, trigger: model.selectedMetric)
    }
}

/// Series chart with exact point inspection plus an accessible table.
/// Every bucket plots (no downsampling); nil buckets render as gaps, never
/// zeros. Selection shows the bucket's exact server value.
public struct SeriesChartView: View {
    private let metric: MetricID
    private let period: Period
    private let periodDate: Date?
    private let timeZone: TimeZone
    @State private var selection: Double?
    @State private var clock = Date()
    private let formatter = MetricFormatter()
    private let points: [SeriesPoint]
    private let xPositions: [Double]
    private let series: TimeSeries

    public init(series: TimeSeries, metric: MetricID, period: Period, periodDate: Date? = nil, timeZone: TimeZone) {
        self.metric = metric
        self.period = period
        self.periodDate = periodDate
        self.timeZone = timeZone
        self.series = series
        let points = SeriesPoints.build(from: series)
        self.points = points
        self.xPositions = points.map { Self.xPosition(for: $0, period: period) }
    }

    private var isDayChart: Bool { period == .day }
    private var isToday: Bool { isDayChart && periodDate == nil }

    private func displayLabel(_ raw: String) -> String {
        BucketLabels.display(raw, for: period, in: timeZone)
    }

    /// Plausible's day graph uses site wall-clock timestamps. Map them onto
    /// a fixed 1,440-minute day so the plot keeps its full width after 00:00.
    private func xPosition(for point: SeriesPoint) -> Double {
        guard xPositions.indices.contains(point.index) else { return Double(point.index) }
        return xPositions[point.index]
    }

    private static func xPosition(for point: SeriesPoint, period: Period) -> Double {
        guard period == .day else { return Double(point.index) }
        let time = point.label.split(separator: " ").last ?? Substring(point.label)
        let components = time.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]), let minute = Int(components[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return Double(point.index) }
        return Double(hour * 60 + minute)
    }

    private var xDomain: ClosedRange<Double> {
        isDayChart ? 0...1439 : 0...Double(max(points.count - 1, 1))
    }

    private var currentMinute: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: clock)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    private var currentHour: Int { Int(currentMinute) / 60 }

    private func axisMinute(_ value: AxisValue) -> Int? {
        guard let minute = value.as(Double.self) else { return nil }
        return Int(minute)
    }

    private var dayYMaximum: Double {
        let actualMaximum = visiblePoints.compactMap(\.value).max() ?? 0
        let estimateMaximum = todayEstimatePoints.map(\.value).max() ?? 0
        return max(1, max(actualMaximum, estimateMaximum) * 1.1)
    }

    private var todayEstimatePoints: [TodayEstimatePoint] {
        isToday ? TodayEstimate.points(for: series, currentMinute: currentMinute) : []
    }

    @ChartContentBuilder
    private var todayEstimateContent: some ChartContent {
        ForEach(todayEstimatePoints) { point in
            LineMark(
                x: .value("Estimated time", point.minute),
                y: .value("Estimated value", point.value),
                series: .value("Series", "Estimate")
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.blue.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
        }
    }

    private var visiblePoints: [SeriesPoint] {
        isToday ? points.filter { xPosition(for: $0) <= currentMinute } : points
    }

    /// Hourly buckets cover the whole hour. Keep the final 23:00 value
    /// visible through the last minute on historical day charts.
    private var finalHourlyBucket: SeriesPoint? {
        guard isDayChart, !isToday, let last = points.last,
              xPosition(for: last) == 23 * 60, last.value != nil
        else { return nil }
        return last
    }

    @ChartContentBuilder
    private var todayIndicatorContent: some ChartContent {
        if isToday {
            RectangleMark(
                xStart: .value("Current hour start", Double(currentHour * 60)),
                xEnd: .value("Current hour end", Double((currentHour + 1) * 60)),
                yStart: .value("Baseline", 0),
                yEnd: .value("Scale", dayYMaximum)
            )
            .foregroundStyle(.orange.opacity(0.08))
            RuleMark(x: .value("Current time", currentMinute))
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("NOW")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
        }
    }

    @ChartContentBuilder
    private var finalHourlyChartContent: some ChartContent {
        if let point = finalHourlyBucket, let value = point.value {
            AreaMark(
                xStart: .value("Last hour start", xPosition(for: point)),
                xEnd: .value("End of day", 1439),
                y: .value("Last hour visitors", value),
                series: .value("Series", "Final hour")
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [.blue.opacity(0.35), .blue.opacity(0.03)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            ForEach([xPosition(for: point), 1439], id: \.self) { minute in
                LineMark(
                    x: .value("Bucket", minute),
                    y: .value("Last hour visitors", value),
                    series: .value("Series", "Final hour")
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue)
            }
        }
    }

    /// Snap touch selection to actual buckets. The chart then changes state
    /// only when the finger crosses into another bucket, not on every pixel.
    private var bucketSelection: Binding<Double?> {
        Binding(
            get: { selection },
            set: { proposed in
                guard let proposed else {
                    if selection != nil { selection = nil }
                    return
                }
                guard let nearest = visiblePoints.min(by: {
                    abs(xPosition(for: $0) - proposed) < abs(xPosition(for: $1) - proposed)
                }) else { return }
                let snapped = xPosition(for: nearest)
                if selection != snapped { selection = snapped }
            }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                todayIndicatorContent
                ForEach(primaryRuns, id: \.firstIndex) { run in
                    ForEach(run.points, id: \.index) { point in
                        LineMark(
                            x: .value("Bucket", xPosition(for: point)),
                            y: .value("Value", point.value!)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(.blue)
                    ForEach(run.points, id: \.index) { point in
                        AreaMark(
                            x: .value("Bucket", xPosition(for: point)),
                            y: .value("Value", point.value!)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.35), .blue.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
                todayEstimateContent
                finalHourlyChartContent
                ForEach(comparisonRuns, id: \.firstIndex) { run in
                    ForEach(run.points, id: \.index) { point in
                        LineMark(
                            x: .value("Bucket", xPosition(for: point)),
                            y: .value("Comparison", point.comparison!)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(.gray)
                    .lineStyle(StrokeStyle(dash: [4, 4]))
                }
                if let selection, let selectedPoint {
                    RuleMark(x: .value("Selected", selection))
                        .foregroundStyle(.secondary)
                    if let value = selectedPoint.value {
                        PointMark(x: .value("Selected", selection), y: .value("Value", value))
                            .foregroundStyle(.white)
                            .symbolSize(220)
                        PointMark(x: .value("Selected", selection), y: .value("Value", value))
                            .foregroundStyle(.blue)
                            .symbolSize(110)
                    }
                }
            }
            .chartXSelection(value: bucketSelection)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                if isDayChart {
                    AxisMarks(values: [0.0, 360, 720, 1080, 1439]) { value in
                        AxisGridLine()
                        if let minute = axisMinute(value) {
                            if minute == 1439 {
                                AxisValueLabel(anchor: .trailing) { Text("23:59") }
                            } else {
                                AxisValueLabel { Text(String(format: "%02d:00", minute / 60)) }
                            }
                        }
                    }
                } else {
                    // Use numeric positions to keep bucket identity stable
                    // while a report's data and chart are being replaced.
                    AxisMarks(values: stridePositions) { value in
                        if let index = value.as(Double.self),
                           let point = points.first(where: { Double($0.index) == index }) {
                            AxisGridLine()
                            AxisValueLabel { Text(displayLabel(point.label)) }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
            }
            .chartYScale(domain: 0...dayYMaximum)
            .frame(minHeight: 150)
            .accessibilityIdentifier("series-chart")
            .accessibilityLabel("\(MetricID.descriptor(for: metric).displayName) chart, \(visiblePoints.count) buckets")
            .accessibilityChartDescriptor(SeriesChartDescriptor(
                title: MetricID.descriptor(for: metric).displayName,
                labels: visiblePoints.map { displayLabel($0.label) },
                values: visiblePoints.compactMap { point in
                    point.value.map { (displayLabel(point.label), $0) }
                }
            ))
            .sensoryFeedback(.selection, trigger: selectedPoint?.index)
            if !todayEstimatePoints.isEmpty {
                Text("Dotted line estimates the rest of today from yesterday.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let detail = selectionDetail {
                Text(detail)
                    .font(.callout)
                    .monospacedDigit()
                    .accessibilityIdentifier("series-selection")
            }
#if os(macOS)
            // Legacy macOS surface keeps the explicit bucket table as its
            // accessible equivalent (its UI suite asserts exact rows);
            // iOS exposes the same values through the chart descriptor.
            VStack(alignment: .leading, spacing: 2) {
                Text("Data table")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("series-table")
                ForEach(visiblePoints, id: \.index) { point in
                    HStack {
                        Text(displayLabel(point.label))
                        Spacer()
                        Text(cellText(point))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(displayLabel(point.label)), \(cellText(point))")
                }
            }
#endif
        }
        .task(id: isToday) {
            guard isToday else { return }
            while !Task.isCancelled {
                let now = Date()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600)
                do {
                    try await Task.sleep(for: .seconds(max(1, nextHour.timeIntervalSince(now))))
                } catch {
                    return
                }
                clock = Date()
            }
        }
        .onChange(of: metric) { _, _ in selection = nil }
        .onChange(of: period) { _, _ in selection = nil }
        .onChange(of: periodDate) { _, _ in selection = nil }
    }

    /// VoiceOver chart content: every bucket as an explorable data point,
    /// replacing the visible hour-by-hour table on iOS.
    struct SeriesChartDescriptor: AXChartDescriptorRepresentable {
        let title: String
        let labels: [String]
        let values: [(x: String, y: Double)]

        func makeChartDescriptor() -> AXChartDescriptor {
            let range = (values.map(\.y).min() ?? 0) ... (values.map(\.y).max() ?? 1)
            return AXChartDescriptor(
                title: title,
                summary: "\(labels.count) buckets",
                xAxis: AXCategoricalDataAxisDescriptor(title: "Time", categoryOrder: labels),
                yAxis: AXNumericDataAxisDescriptor(
                    title: title,
                    range: range,
                    gridlinePositions: [],
                    valueDescriptionProvider: { value in
                        let formatted = NumberFormatter()
                        formatted.numberStyle = .decimal
                        formatted.maximumFractionDigits = 2
                        return formatted.string(from: NSNumber(value: value)) ?? "\(value)"
                    }
                ),
                series: [
                    AXDataSeriesDescriptor(
                        name: title,
                        isContinuous: false,
                        dataPoints: values.map { AXDataPoint(x: $0.x, y: $0.y) }
                    ),
                ]
            )
        }
    }

    private var primaryRuns: [PointRun] {
        runs(value: \.value, in: visiblePoints).map { PointRun(points: $0, kind: .primary) }
    }

    private var stridePositions: [Double] {
        let stride = max(1, (points.count + 5) / 6)
        return points.enumerated().filter { $0.offset % stride == 0 }.map { Double($0.offset) }
    }

    private var comparisonRuns: [PointRun] {
        guard !isToday, visiblePoints.contains(where: { $0.comparison != nil }) else { return [] }
        return runs(value: \.comparison, in: visiblePoints).map { PointRun(points: $0, kind: .comparison) }
    }

    /// Contiguous non-nil runs so lines never bridge genuine gaps.
    private func runs(value keyPath: KeyPath<SeriesPoint, Double?>, in points: [SeriesPoint]) -> [[SeriesPoint]] {
        var groups: [[SeriesPoint]] = []
        var current: [SeriesPoint] = []
        for point in points {
            if point[keyPath: keyPath] != nil {
                current.append(point)
            } else if !current.isEmpty {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private var selectionDetail: String? {
        guard selection != nil, let point = selectedPoint else { return nil }
        var text = "\(displayLabel(point.label)): \(cellText(point))"
        if let rawComparison = point.rawComparison {
            text += " (comparison \(formatter.string(for: rawComparison, as: metric)))"
        }
        return text
    }

    private var selectedPoint: SeriesPoint? {
        guard let selection, !points.isEmpty else { return nil }
        guard let nearest = visiblePoints.min(by: { abs(xPosition(for: $0) - selection) < abs(xPosition(for: $1) - selection) }),
              abs(xPosition(for: nearest) - selection) <= (isDayChart ? 2 : 0.5)
        else { return nil }
        return nearest
    }

    private func cellText(_ point: SeriesPoint) -> String {
        guard let raw = point.rawValue else { return "no data" }
        return formatter.string(for: raw, as: metric)
    }
}

private enum RunKind { case primary, comparison }

private struct PointRun {
    let points: [SeriesPoint]
    let kind: RunKind
    var firstIndex: Int { points.first?.index ?? -1 }
}
