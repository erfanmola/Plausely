import AnalyticsCore
import AppIntents
import Charts
import Foundation
import PlausibleClient
import SwiftUI
import WidgetKit

struct WidgetSiteEntity: AppEntity, Hashable, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Website")
    static let defaultQuery = WidgetSiteEntityQuery()

    let id: String
    let domain: String
    let accountID: String

    init(option: WidgetSiteOption) {
        id = option.id
        domain = option.domain
        accountID = option.accountID.rawValue.uuidString
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(domain)")
    }
}

struct WidgetSiteEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSiteEntity] {
        let wanted = Set(identifiers)
        return await availableSites().filter { wanted.contains($0.id) }.map(WidgetSiteEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetSiteEntity] {
        await availableSites().map(WidgetSiteEntity.init)
    }

    func defaultResult() async -> WidgetSiteEntity? {
        await availableSites().first.map(WidgetSiteEntity.init)
    }

    private func availableSites() async -> [WidgetSiteOption] {
        let cached = WidgetSiteCatalog.all()
        guard cached.isEmpty else { return cached }
        guard let store = try? AccountStore.production(),
              let accountIDs = try? store.allIDs() else { return [] }

        let credentials = KeychainCredentialStore(
            accessGroup: Bundle.main.infoDictionary?["PlauselyKeychainAccessGroup"] as? String
        )
        let transport = URLSessionTransport()
        var discoveredOptions: [WidgetSiteOption] = []

        for accountID in accountIDs {
            guard let record = try? store.load(id: accountID) else { continue }
            let options: [WidgetSiteOption]
            if let sharedLink = record.sharedLink {
                options = [WidgetSiteOption(
                    accountID: accountID,
                    domain: sharedLink.domain,
                    teamID: nil,
                    timeZoneID: nil
                )]
            } else {
                let coordinator = SessionCoordinator(
                    bridge: WebAuthenticationBridge(baseURL: record.baseURL),
                    credentials: credentials,
                    accounts: store,
                    transport: transport
                )
                guard let sites = try? await CE321SiteDiscovery(
                    coordinator: coordinator, transport: transport
                ).discover(account: accountID) else { continue }
                options = sites.map { site in
                    WidgetSiteOption(
                        accountID: accountID,
                        domain: site.domain,
                        teamID: site.teamIdentifier,
                        timeZoneID: nil
                    )
                }
            }

            if !options.isEmpty {
                WidgetSiteCatalog.replace(accountID: accountID, with: options)
                discoveredOptions.append(contentsOf: options)
            }
        }

        return discoveredOptions.sorted {
            $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
    }
}

enum WidgetPeriod: String, AppEnum {
    case realtime, today, last7Days, last28Days, last30Days, last91Days
    case monthToDate, last6Months, last12Months, yearToDate, allTime

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Period")
    static let caseDisplayRepresentations: [WidgetPeriod: DisplayRepresentation] = [
        .realtime: "Realtime", .today: "Today", .last7Days: "Last 7 days",
        .last28Days: "Last 28 days", .last30Days: "Last 30 days",
        .last91Days: "Last 91 days", .monthToDate: "Month to date",
        .last6Months: "Last 6 months", .last12Months: "Last 12 months",
        .yearToDate: "Year to date", .allTime: "All time",
    ]

    var dashboardPeriod: Period {
        switch self {
        case .realtime: .realtime
        case .today: .day
        case .last7Days: .days7
        case .last28Days: .days28
        case .last30Days: .days30
        case .last91Days: .days91
        case .monthToDate: .month
        case .last6Months: .months6
        case .last12Months: .months12
        case .yearToDate: .year
        case .allTime: .all
        }
    }
}

enum WidgetRefreshCadence: String, AppEnum {
    case fifteenMinutes, thirtyMinutes, oneHour, sixHours

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Update interval")
    static let caseDisplayRepresentations: [WidgetRefreshCadence: DisplayRepresentation] = [
        .fifteenMinutes: "15 minutes", .thirtyMinutes: "30 minutes",
        .oneHour: "1 hour", .sixHours: "6 hours",
    ]

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        }
    }
}

struct PlauselyWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Plausely Analytics"
    static let description = IntentDescription("Choose a website, reporting period, and requested refresh interval. WidgetKit may delay updates to manage battery use.")

    @Parameter(title: "Website") var website: WidgetSiteEntity?
    @Parameter(title: "Period", default: .last28Days) var period: WidgetPeriod
    @Parameter(title: "Update interval", default: .thirtyMinutes) var refreshCadence: WidgetRefreshCadence

    init() {}
}

struct RefreshPlauselyWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Plausely"
    static let description = IntentDescription("Fetch the latest analytics for this widget.")

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "PlauselyAnalyticsWidget")
        return .result()
    }
}

struct PlauselyWidgetEntry: TimelineEntry {
    let date: Date
    let domain: String
    let period: String
    let refreshCadence: WidgetRefreshCadence
    let destinationURL: URL?
    let metrics: [(name: String, value: String)]
    let chartValues: [Double?]
    let chartEstimateValues: [Double?]
    let chartCurrentMinute: Double?
    let error: String?

    static func placeholder(at date: Date = .now) -> Self {
        Self(date: date, domain: "your-site.com", period: "Last 28 days", refreshCadence: .thirtyMinutes,
             destinationURL: nil,
             metrics: [("Visitors", "12,480"), ("Visits", "15,204"), ("Pageviews", "28,710")],
             chartValues: [2, 3, 2, 5, 4, 7, 6, 8, 7, 9], chartEstimateValues: [],
             chartCurrentMinute: nil, error: nil)
    }
}

struct PlauselyWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlauselyWidgetEntry { .placeholder() }

    func snapshot(for configuration: PlauselyWidgetConfiguration, in context: Context) async -> PlauselyWidgetEntry {
        if context.isPreview { return .placeholder() }
        return await WidgetReportLoader.load(configuration)
    }

    func timeline(for configuration: PlauselyWidgetConfiguration, in context: Context) async -> Timeline<PlauselyWidgetEntry> {
        let entry = await WidgetReportLoader.load(configuration)
        let nextRequest = WidgetReportLoader.nextRefresh(after: entry.date, cadence: configuration.refreshCadence, timeZone: WidgetReportLoader.siteTimeZone(configuration))
        return Timeline(entries: [entry], policy: .after(nextRequest))
    }
}

private enum WidgetReportLoader {
    static func load(_ configuration: PlauselyWidgetConfiguration) async -> PlauselyWidgetEntry {
        let now = Date()
        guard let site = configuration.website,
              let uuid = UUID(uuidString: site.accountID) else {
            return failure(configuration, message: "Open Plausely and choose a website first.", date: now)
        }
        do {
            guard let store = try? AccountStore.production(),
                  let record = try store.load(id: AccountID(rawValue: uuid)) else {
                return failure(configuration, message: "Instance unavailable. Open Plausely to sign in again.", date: now)
            }
            let credentials = KeychainCredentialStore(
                accessGroup: Bundle.main.infoDictionary?["PlauselyKeychainAccessGroup"] as? String
            )
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let transport = FreshWidgetTransport(base: URLSessionTransport(configuration: sessionConfiguration))
            let coordinator = SessionCoordinator(
                bridge: WebAuthenticationBridge(baseURL: record.baseURL),
                credentials: credentials,
                accounts: store,
                transport: transport
            )
            let adapter: CE321DashboardAdapter
            if let shared = record.sharedLink {
                adapter = CE321DashboardAdapter(
                    coordinator: coordinator, transport: transport,
                    sharedBase: record.baseURL, sharedAuth: shared.slug
                )
            } else {
                adapter = CE321DashboardAdapter(coordinator: coordinator, transport: transport)
            }
            let option = WidgetSiteCatalog.all().first { $0.id == site.id }
            let zone = option?.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
            let period = configuration.period.dashboardPeriod
            if period == .realtime {
                let current = try await adapter.currentVisitors(account: AccountID(rawValue: uuid), site: SiteID(domain: site.domain))
                return PlauselyWidgetEntry(
                    date: now, domain: site.domain, period: "Realtime",
                    refreshCadence: configuration.refreshCadence,
                    destinationURL: WidgetSiteDestination(accountID: AccountID(rawValue: uuid), domain: site.domain).url,
                    metrics: [("Current visitors", NumberFormatter.localizedString(from: NSNumber(value: current.count), number: .decimal))],
                    chartValues: [],
                    chartEstimateValues: [],
                    chartCurrentMinute: nil,
                    error: nil
                )
            }
            // Plausible's day graph only accepts minute buckets. The API
            // rejects hour buckets for `period=day`.
            let interval: ChartInterval = period == .day ? .minute : .day
            let query = DashboardQuery(
                accountID: AccountID(rawValue: uuid),
                siteID: SiteID(domain: site.domain, teamID: option?.teamID),
                period: period,
                periodDate: period == .day ? now : nil,
                comparison: period == .day ? .previousPeriod : .off,
                interval: interval,
                selectedMetric: .visitors,
                timeZone: zone
            )
            let report = try await adapter.overview(query, today: now)
            let series = try await adapter.series(query, today: now).value
            let formatter = MetricFormatter()
            let metrics = report.value.stats.prefix(8).map { stat in
                (stat.name, formatter.string(for: stat.value, as: stat.metric))
            }
            let chartValues: [Double?]
            let chartCurrentMinute: Double?
            if period == .day {
                chartCurrentMinute = Self.currentMinute(at: now, in: zone)
                chartValues = Self.hourlyTodayValues(
                    labels: series.labels,
                    values: series.plot,
                    currentMinute: chartCurrentMinute ?? 0
                )
            } else {
                chartCurrentMinute = nil
                chartValues = series.plot.map(Self.doubleValue)
            }
            let chartEstimateValues: [Double?]
            if period == .day, let comparisonLabels = series.comparisonLabels,
               let comparisonPlot = series.comparisonPlot {
                chartEstimateValues = Self.hourlyTodayValues(
                    labels: comparisonLabels,
                    values: comparisonPlot,
                    currentMinute: 1439
                )
            } else {
                chartEstimateValues = []
            }
            return PlauselyWidgetEntry(
                date: now,
                domain: site.domain,
                period: Self.periodTitle(configuration.period),
                refreshCadence: configuration.refreshCadence,
                destinationURL: WidgetSiteDestination(accountID: AccountID(rawValue: uuid), domain: site.domain).url,
                metrics: metrics,
                chartValues: chartValues,
                chartEstimateValues: chartEstimateValues,
                chartCurrentMinute: chartCurrentMinute,
                error: metrics.isEmpty ? "No analytics for this period." : nil
            )
        } catch {
            return failure(configuration, message: "Couldn't refresh analytics. Open Plausely to check the connection.", date: now)
        }
    }

    private static func failure(_ configuration: PlauselyWidgetConfiguration, message: String, date: Date) -> PlauselyWidgetEntry {
        PlauselyWidgetEntry(
            date: date,
            domain: configuration.website?.domain ?? "Plausely",
            period: Self.periodTitle(configuration.period),
            refreshCadence: configuration.refreshCadence,
            destinationURL: configuration.website.flatMap { site in
                guard let uuid = UUID(uuidString: site.accountID) else { return nil }
                return WidgetSiteDestination(accountID: AccountID(rawValue: uuid), domain: site.domain).url
            },
            metrics: [],
            chartValues: [],
            chartEstimateValues: [],
            chartCurrentMinute: nil,
            error: message
        )
    }

    static func siteTimeZone(_ configuration: PlauselyWidgetConfiguration) -> TimeZone {
        guard let id = configuration.website.flatMap({ site in WidgetSiteCatalog.all().first { $0.id == site.id }?.timeZoneID }),
              let timeZone = TimeZone(identifier: id) else { return .current }
        return timeZone
    }

    static func nextRefresh(after date: Date, cadence: WidgetRefreshCadence, timeZone: TimeZone) -> Date {
        let cadenceDate = date.addingTimeInterval(cadence.seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? cadenceDate
        return min(cadenceDate, midnight)
    }

    private static func currentMinute(at date: Date, in timeZone: TimeZone) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        return Double((clock.hour ?? 0) * 60 + (clock.minute ?? 0))
    }

    private static func hourlyTodayValues(
        labels: [String], values: [MetricValue?], currentMinute: Double
    ) -> [Double?] {
        let currentHour = Int(currentMinute) / 60
        var totals = Array(repeating: 0.0, count: 24)
        var counts = Array(repeating: 0, count: 24)

        for (index, label) in labels.enumerated() where index < values.count {
            let time = label.split(separator: " ").last.map(String.init) ?? label
            guard let hourText = time.split(separator: ":").first,
                  let hour = Int(hourText), (0..<24).contains(hour), hour <= currentHour,
                  let rawValue = values[index], let value = doubleValue(rawValue)
            else { continue }
            totals[hour] += value
            counts[hour] += 1
        }

        return (0..<24).map { hour in
            guard hour <= currentHour, counts[hour] > 0 else { return nil }
            return totals[hour] / Double(counts[hour])
        }
    }

    private static func doubleValue(_ value: MetricValue?) -> Double? {
        guard let value else { return nil }
        return switch value {
        case .count(let number): Double(number)
        case .decimal(let number): NSDecimalNumber(decimal: number).doubleValue
        case .unavailable: nil
        }
    }

    private static func periodTitle(_ period: WidgetPeriod) -> String {
        switch period {
        case .realtime: "Realtime"
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last28Days: "Last 28 days"
        case .last30Days: "Last 30 days"
        case .last91Days: "Last 91 days"
        case .monthToDate: "Month to date"
        case .last6Months: "Last 6 months"
        case .last12Months: "Last 12 months"
        case .yearToDate: "Year to date"
        case .allTime: "All time"
        }
    }
}

struct PlauselyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlauselyWidgetEntry

    var body: some View {
        VStack(alignment: .center, spacing: family == .systemSmall ? 7 : 6) {
            HStack(spacing: 6) {
                Text(entry.domain)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.period)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if family != .systemSmall {
                    refreshButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            if let error = entry.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
            } else if family == .systemSmall {
                smallContent
            } else {
                expandedContent
            }
            if family == .systemLarge || family == .systemExtraLarge {
                Text("Updated \(entry.date, style: .time)")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, family == .systemSmall ? 12 : 14)
        .padding(.vertical, family == .systemSmall ? 10 : 11)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var smallContent: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(entry.metrics.first?.value ?? "—")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(entry.metrics.first?.name ?? "Visitors")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            if !entry.chartValues.isEmpty {
                WidgetSparkline(values: entry.chartValues, estimateValues: entry.chartEstimateValues,
                                height: 40, chartCurrentMinute: entry.chartCurrentMinute)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var refreshButton: some View {
        Button(intent: RefreshPlauselyWidgetIntent()) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh analytics")
    }

    private var expandedContent: some View {
        let count = family == .systemMedium ? 4 : (family == .systemLarge ? 6 : 8)
        let chartHeight: CGFloat = switch family {
        case .systemMedium: 34
        case .systemLarge: 110
        default: 126
        }
        return VStack(alignment: .center, spacing: 5) {
            WidgetSparkline(
                values: entry.chartValues,
                estimateValues: entry.chartEstimateValues,
                height: chartHeight,
                chartCurrentMinute: entry.chartCurrentMinute
            )

            LazyVStack(alignment: .center, spacing: 4) {
                ForEach(Array(entry.metrics.prefix(count).enumerated()), id: \.offset) { item in
                    let metric = item.element
                    HStack(spacing: 8) {
                        Text(metric.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(metric.value)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
}

private struct WidgetSparkline: View {
    let values: [Double?]
    let estimateValues: [Double?]
    let height: CGFloat
    let chartCurrentMinute: Double?

    private var estimatePoints: [(minute: Double, value: Double)] {
        guard let chartCurrentMinute, chartCurrentMinute < 1439 else { return [] }
        let currentHour = Int(chartCurrentMinute) / 60
        guard let anchorHour = values.indices.last(where: { $0 <= currentHour && values[$0] != nil }),
              let anchorValue = values[anchorHour],
              estimateValues.indices.contains(currentHour),
              let comparisonAnchor = estimateValues[currentHour] else { return [] }
        let offset = anchorValue - comparisonAnchor
        var points: [(minute: Double, value: Double)] = [
            (Double(anchorHour * 60 + 30), anchorValue),
            (chartCurrentMinute, anchorValue),
        ]
        guard currentHour < 23 else { return [] }
        for hour in (currentHour + 1)..<24 {
            guard estimateValues.indices.contains(hour), let value = estimateValues[hour] else { break }
            points.append((Double(hour * 60 + 30), value + offset))
        }
        return points.count > 2 ? points : []
    }

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { item in
                if let value = item.element {
                    let x = chartCurrentMinute == nil ? Double(item.offset) : Double(item.offset * 60 + 30)
                    AreaMark(x: .value("Bucket", x), y: .value("Visitors", value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.tint.opacity(0.14))
                    LineMark(x: .value("Bucket", x), y: .value("Visitors", value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(Array(estimatePoints.enumerated()), id: \.offset) { item in
                let point = item.element
                LineMark(
                    x: .value("Estimated time", point.minute),
                    y: .value("Estimated visitors", point.value),
                    series: .value("Series", "Estimate")
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.tint.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
            }
            if let chartCurrentMinute = chartCurrentMinute {
                RuleMark(x: .value("Current time", chartCurrentMinute))
                    .foregroundStyle(.tint.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
        }
        .widgetAccentable()
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: chartCurrentMinute == nil ? 0...Double(max(values.count - 1, 1)) : 0...1439)
        .chartYScale(domain: .automatic(includesZero: true))
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct FreshWidgetTransport: HTTPTransport {
    let base: any HTTPTransport

    func send(_ request: URLRequest, expecting: ContentKind) async throws -> (Data, HTTPURLResponse) {
        var freshRequest = request
        freshRequest.cachePolicy = .reloadIgnoringLocalCacheData
        freshRequest.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        freshRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return try await base.send(freshRequest, expecting: expecting)
    }
}

struct PlauselyAnalyticsWidget: Widget {
    let kind = "PlauselyAnalyticsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PlauselyWidgetConfiguration.self, provider: PlauselyWidgetProvider()) { entry in
            PlauselyWidgetView(entry: entry)
                .widgetURL(entry.destinationURL)
        }
        .configurationDisplayName("Plausely Analytics")
        .description("Keep analytics for a chosen website and period in view. Refreshes may be delayed by WidgetKit.")
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct PlauselyWidgetBundle: WidgetBundle {
    var body: some Widget { PlauselyAnalyticsWidget() }
}
