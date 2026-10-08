import AnalyticsCore
import Foundation

/// Point-ready form of one series bucket. `value`/`comparison` are nil for
/// genuine gaps (server nulls); the chart renders gaps, never zeros.
public struct SeriesPoint: Sendable {
    public let index: Int
    public let label: String
    public let value: Double?
    public let comparison: Double?
    public let rawValue: MetricValue?
    public let rawComparison: MetricValue?

    public init(index: Int, label: String, value: Double?, comparison: Double?, rawValue: MetricValue?, rawComparison: MetricValue?) {
        self.index = index
        self.label = label
        self.value = value
        self.comparison = comparison
        self.rawValue = rawValue
        self.rawComparison = rawComparison
    }
}

/// Plot helpers. Totals are never computed here: headline numbers come only
/// from the server's `top-stats` aggregates (non-additive metrics refuse
/// client-side sums by contract).
public enum SeriesPoints {
    /// One point per bucket, order-preserved, nils kept positional.
    public static func build(from series: TimeSeries) -> [SeriesPoint] {
        series.labels.enumerated().map { index, label in
            let raw = index < series.plot.count ? series.plot[index] : nil
            let rawComparison = series.comparisonPlot.flatMap { index < $0.count ? $0[index] : nil } ?? nil
            return SeriesPoint(
                index: index,
                label: label,
                value: raw.flatMap(plotDouble),
                comparison: rawComparison.flatMap(plotDouble),
                rawValue: raw,
                rawComparison: rawComparison
            )
        }
    }

    /// Chart coordinate for one value. Unavailable maps to nil (gap).
    public static func plotDouble(_ value: MetricValue) -> Double? {
        switch value {
        case .count(let amount): return Double(amount)
        case .decimal(let amount): return NSDecimalNumber(decimal: amount).doubleValue
        case .unavailable: return nil
        }
    }
}

/// Noncolor change text: direction is carried by arrow + sign + words, never
/// color alone (MET-04).
public func changeText(_ change: Int?) -> String? {
    guard let change else { return nil }
    if change > 0 { return "▲ +\(change)% vs comparison" }
    if change < 0 { return "▼ \(change)% vs comparison" }
    return "■ 0% vs comparison"
}

/// Overview coordinator (04.4): metric selection over two independent report
/// lifecycles. `reload` runs both reports for the effective query (series with
/// the selected metric applied); `reselect` reloads the series only, so the
/// overview cards never flicker on a metric switch.
@MainActor
@Observable
public final class OverviewModel {
    /// Chart metrics selectable on the overview series (MET-01 traffic set).
    public static let chartMetrics: [MetricID] = [
        .visitors, .visits, .pageviews, .viewsPerVisit, .bounceRate, .visitDuration,
    ]

    public var selectedMetric: MetricID
    public let dashboard: DashboardModel
    public private(set) var lastQuery: DashboardQuery?

    public init(
        selectedMetric: MetricID = .visitors,
        overviewLoader: @escaping ReportModel<Overview>.Loader,
        seriesLoader: @escaping ReportModel<TimeSeries>.Loader,
        overviewCache: ReportCache<Overview>? = nil,
        seriesCache: ReportCache<TimeSeries>? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.selectedMetric = selectedMetric
        self.dashboard = DashboardModel(
            overviewLoader: overviewLoader,
            seriesLoader: seriesLoader,
            overviewCache: overviewCache,
            seriesCache: seriesCache,
            clock: clock
        )
    }

    public func reload(query: DashboardQuery, today: Date? = nil) async {
        lastQuery = query
        async let first: () = dashboard.overview.load(query: query, today: today)
        async let second: () = dashboard.series.load(query: seriesQuery(from: query), today: today)
        await first
        await second
    }

    /// Applies a new chart metric to the last query and reloads the series
    /// only. Returns false when no query has loaded yet.
    @discardableResult
    public func reselect(_ metric: MetricID, today: Date? = nil) async -> Bool {
        selectedMetric = metric
        guard let lastQuery else { return false }
        await dashboard.series.load(query: seriesQuery(from: lastQuery), today: today)
        return true
    }

    public func refresh(today: Date? = nil) async {
        await dashboard.refresh(today: today)
    }

    private func seriesQuery(from query: DashboardQuery) -> DashboardQuery {
        DashboardQuery(
            accountID: query.accountID,
            siteID: query.siteID,
            period: query.period,
            periodDate: query.periodDate,
            comparison: query.comparison,
            matchDayOfWeek: query.matchDayOfWeek,
            filters: query.filters,
            includeImported: query.includeImported,
            interval: query.interval,
            selectedMetric: selectedMetric,
            timeZone: query.timeZone
        )
    }
}
