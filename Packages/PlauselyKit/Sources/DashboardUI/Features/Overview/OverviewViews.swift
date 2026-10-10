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
                SeriesChartView(series: $0.value, metric: model.selectedMetric, period: query.period, timeZone: query.timeZone)
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
        .accessibilityIdentifier("metric-picker")
        .sensoryFeedback(.selection, trigger: model.selectedMetric)
    }
}

/// Series chart with exact point inspection plus an accessible table.
/// Every bucket plots (no downsampling); nil buckets render as gaps, never
/// zeros. Selection shows the bucket's exact server value.
public struct SeriesChartView: View {
    private let series: TimeSeries
    private let metric: MetricID
    private let period: Period
    private let timeZone: TimeZone
    @State private var selection: String?
    private let formatter = MetricFormatter()

    public init(series: TimeSeries, metric: MetricID, period: Period, timeZone: TimeZone) {
        self.series = series
        self.metric = metric
        self.period = period
        self.timeZone = timeZone
    }

    private var points: [SeriesPoint] { SeriesPoints.build(from: series) }

    private func displayLabel(_ raw: String) -> String {
        BucketLabels.display(raw, for: period, in: timeZone)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(primaryRuns, id: \.firstIndex) { run in
                    ForEach(run.points, id: \.index) { point in
                        LineMark(
                            x: .value("Bucket", point.label),
                            y: .value("Value", point.value!)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(.blue)
                    ForEach(run.points, id: \.index) { point in
                        AreaMark(
                            x: .value("Bucket", point.label),
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
                ForEach(comparisonRuns, id: \.firstIndex) { run in
                    ForEach(run.points, id: \.index) { point in
                        LineMark(
                            x: .value("Bucket", point.label),
                            y: .value("Comparison", point.comparison!)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    .foregroundStyle(.gray)
                    .lineStyle(StrokeStyle(dash: [4, 4]))
                }
                if let selection {
                    RuleMark(x: .value("Selected", selection))
                        .foregroundStyle(.secondary)
                    if let point = points.first(where: { $0.label == selection }),
                       let value = point.value {
                        PointMark(x: .value("Selected", selection), y: .value("Value", value))
                            .foregroundStyle(.white)
                            .symbolSize(220)
                        PointMark(x: .value("Selected", selection), y: .value("Value", value))
                            .foregroundStyle(.blue)
                            .symbolSize(110)
                    }
                }
            }
            .chartXSelection(value: $selection)
            .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 0))
            .chartXAxis {
                // Labels render only for strided positions: explicit value
                // lists are not honored for string categories, so the
                // content gate (not the values list) is what caps labels.
                // Gridlines follow the same gate, so sparse buckets never
                // drown in lines either.
                AxisMarks(values: strideLabels) { value in
                    if let raw = value.as(String.self), strideSet.contains(raw) {
                        AxisGridLine()
                        AxisValueLabel {
                            Text(displayLabel(raw))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
            }
            .frame(minHeight: 150)
            .accessibilityIdentifier("series-chart")
            .accessibilityLabel("\(MetricID.descriptor(for: metric).displayName) chart, \(points.count) buckets")
            .accessibilityChartDescriptor(SeriesChartDescriptor(
                title: MetricID.descriptor(for: metric).displayName,
                labels: points.map { displayLabel($0.label) },
                values: points.compactMap { point in
                    point.value.map { (displayLabel(point.label), $0) }
                }
            ))
            .animation(.snappy, value: series)
            .sensoryFeedback(.selection, trigger: selection)
            if let detail = selectionDetail {
                Text(detail)
                    .font(.callout)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: detail)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                ForEach(points, id: \.index) { point in
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
        runs(value: \.value).map { PointRun(points: $0, kind: .primary) }
    }

    /// Every Nth bucket label, capped so at most ~6 land on the axis.
    /// Matched by content (not just the values list) so labels can
    /// never collide however the axis resolves marks.
    private var strideLabels: [String] {
        let stride = max(1, (points.count + 5) / 6)
        return points.enumerated().filter { $0.offset % stride == 0 }.map(\.element.label)
    }

    private var strideSet: Set<String> { Set(strideLabels) }

    private var comparisonRuns: [PointRun] {
        guard points.contains(where: { $0.comparison != nil }) else { return [] }
        return runs(value: \.comparison).map { PointRun(points: $0, kind: .comparison) }
    }

    /// Contiguous non-nil runs so lines never bridge genuine gaps.
    private func runs(value keyPath: KeyPath<SeriesPoint, Double?>) -> [[SeriesPoint]] {
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
        guard let selection,
              let point = points.first(where: { $0.label == selection })
        else { return nil }
        var text = "\(displayLabel(point.label)): \(cellText(point))"
        if let rawComparison = point.rawComparison {
            text += " (comparison \(formatter.string(for: rawComparison, as: metric)))"
        }
        return text
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
