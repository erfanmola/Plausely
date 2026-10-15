import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@MainActor
private func baseQuery(metric: MetricID = .visits) -> DashboardQuery {
    DashboardQuery(
        accountID: AccountID(),
        siteID: SiteID(domain: "shop.example"),
        period: .days28,
        comparison: .off,
        filters: .empty,
        includeImported: false,
        interval: .day,
        selectedMetric: metric,
        timeZone: TimeZone(identifier: "UTC")!
    )
}

private let frozenToday = Date(timeIntervalSince1970: 1_790_000_000)

private actor Recorder {
    var overviewQueries: [DashboardQuery] = []
    var seriesQueries: [DashboardQuery] = []

    func overviewLoader() -> ReportModel<Overview>.Loader {
        { query, today in
            await self.recordOverview(query)
            let id = try QueryID.compute(for: query, today: today)
            return ReportEnvelope(
                queryID: id,
                value: Overview(stats: [
                    TopStat(metric: .visitors, name: "Unique visitors", value: .count(1600)),
                ]),
                retrievedAt: today
            )
        }
    }

    func seriesLoader() -> ReportModel<TimeSeries>.Loader {
        { query, today in
            await self.recordSeries(query)
            let id = try QueryID.compute(for: query, today: today)
            return ReportEnvelope(
                queryID: id,
                value: TimeSeries(
                    metric: query.selectedMetric,
                    labels: ["a", "b", "c"],
                    plot: [.count(3), nil, .count(7)]
                ),
                retrievedAt: today
            )
        }
    }

    private func recordOverview(_ query: DashboardQuery) { overviewQueries.append(query) }
    private func recordSeries(_ query: DashboardQuery) { seriesQueries.append(query) }
}

@Suite("overview metrics and charts (04.4)")
@MainActor
struct OverviewTests {
    private func makeModel(_ recorder: Recorder) async -> OverviewModel {
        OverviewModel(
            overviewLoader: await recorder.overviewLoader(),
            seriesLoader: await recorder.seriesLoader()
        )
    }

    @Test("reload runs overview with the effective query, series with the selected metric")
    func reloadAppliesMetric() async throws {
        let recorder = Recorder()
        let model = await makeModel(recorder)
        try await model.reload(query: baseQuery(metric: .visits), today: frozenToday)
        let overviewQuery = try #require(await recorder.overviewQueries.last)
        #expect(overviewQuery.selectedMetric == .visits)
        let seriesQuery = try #require(await recorder.seriesQueries.last)
        #expect(seriesQuery.selectedMetric == .visitors)
        #expect(seriesQuery.period == .days28)
        if case .loaded = model.dashboard.overview.state {} else {
            Issue.record("overview should be loaded")
        }
        if case .loaded = model.dashboard.series.state {} else {
            Issue.record("series should be loaded")
        }
    }

    @Test("reselect reloads the series only and reports when nothing loaded yet")
    func reselectSeriesOnly() async throws {
        let recorder = Recorder()
        let model = await makeModel(recorder)
        #expect(await model.reselect(.pageviews, today: frozenToday) == false)
        try await model.reload(query: baseQuery(), today: frozenToday)
        let overviewCount = await recorder.overviewQueries.count
        #expect(await model.reselect(.pageviews, today: frozenToday) == true)
        #expect(model.selectedMetric == .pageviews)
        #expect(await recorder.overviewQueries.count == overviewCount)
        #expect(try #require(await recorder.seriesQueries.last).selectedMetric == .pageviews)
    }

    @Test("points keep every bucket with positional nil gaps")
    func pointsPreserveBuckets() {
        let series = TimeSeries(
            metric: .visitors,
            labels: ["a", "b", "c"],
            plot: [.count(3), nil, .count(7)],
            comparisonPlot: [.count(1), .count(2), nil]
        )
        let points = SeriesPoints.build(from: series)
        #expect(points.count == 3)
        #expect(points[0].value == 3)
        #expect(points[1].value == nil)
        #expect(points[1].rawValue == nil)
        #expect(points[2].value == 7)
        #expect(points[0].comparison == 1)
        #expect(points[2].comparison == nil)
    }

    @Test("plot coordinates carry server precision, unavailable stays a gap")
    func plotDoubles() {
        #expect(SeriesPoints.plotDouble(.count(12)) == 12)
        let plotted = try! #require(SeriesPoints.plotDouble(.decimal(Decimal(string: "0.88")!)))
        #expect(abs(plotted - 0.88) < 0.000_001)
        #expect(SeriesPoints.plotDouble(.unavailable(.null)) == nil)
    }

    @Test("change direction never relies on color alone")
    func changeTextCases() {
        #expect(DashboardUI.changeText(nil) == nil)
        #expect(DashboardUI.changeText(12) == "▲ +12% vs comparison")
        #expect(DashboardUI.changeText(-3) == "▼ -3% vs comparison")
        #expect(DashboardUI.changeText(0) == "■ 0% vs comparison")
    }

    @Test("lower is better for bounce, exit rate, and position")
    func changeSentimentCases() {
        #expect(ChangeSentiment.of(nil, for: .visitors) == .neutral)
        #expect(ChangeSentiment.of(0, for: .visitors) == .neutral)
        #expect(ChangeSentiment.of(12, for: .visitors) == .positive)
        #expect(ChangeSentiment.of(-5, for: .visits) == .negative)
        #expect(ChangeSentiment.of(-4, for: .bounceRate) == .positive)
        #expect(ChangeSentiment.of(4, for: .bounceRate) == .negative)
        #expect(ChangeSentiment.of(-8, for: .exitRate) == .positive)
        #expect(ChangeSentiment.of(-2, for: .position) == .positive)
        #expect(ChangeSentiment.of(2, for: .position) == .negative)
        #expect(ChangeSentiment.of(25, for: .ctr) == .positive)
    }

    @Test("mock series omits comparison without a comparison mode")
    func mockComparisonGuard() async throws {
        let off = try await MockOverviewProviders.series(baseQuery(), frozenToday).value
        #expect(off.comparisonPlot == nil)
        #expect(off.plot.count == 8)
        #expect(off.plot[2] == nil)
        var comparing = baseQuery()
        comparing = DashboardQuery(
            accountID: comparing.accountID,
            siteID: comparing.siteID,
            period: comparing.period,
            comparison: .previousPeriod,
            filters: comparing.filters,
            includeImported: comparing.includeImported,
            interval: comparing.interval,
            selectedMetric: comparing.selectedMetric,
            timeZone: comparing.timeZone
        )
        let on = try await MockOverviewProviders.series(comparing, frozenToday).value
        #expect(on.comparisonPlot?.count == 8)
    }

    @Test("mock overview mirrors the frozen top-stats numbers")
    func mockOverviewGolden() async throws {
        let envelope = try await MockOverviewProviders.overview(baseQuery(), frozenToday).value
        let values = envelope.stats.map(\.value)
        #expect(values.contains(.count(1600)))
        #expect(values.contains(.count(1400)))
        #expect(values.contains(.decimal(Decimal(string: "0.88")!)))
        #expect(values.contains(.count(88)))
    }
}

@Suite("headline trend deltas")
@MainActor
struct TrendDeltasTests {
    private var plain: [TopStat] {
        [TopStat(metric: .visitors, name: "Unique visitors", value: .count(1600))]
    }

    private var delta: [TopStat] {
        [TopStat(metric: .visitors, name: "Unique visitors", value: .count(1500), comparisonValue: .count(1400), change: 7)]
    }

    @Test("nil trend leaves stats untouched")
    func nilTrend() {
        #expect(TrendDeltas.apply(to: plain, from: nil) == plain)
    }

    @Test("trend fills missing change and comparison only")
    func fillsMissing() {
        let merged = TrendDeltas.apply(to: plain, from: Overview(stats: delta))
        #expect(merged.count == 1)
        #expect(merged[0].value == .count(1600))
        #expect(merged[0].comparisonValue == .count(1400))
        #expect(merged[0].change == 7)
    }

    @Test("main values and deltas win over trend")
    func mainWins() {
        let main = [TopStat(metric: .visitors, name: "Unique visitors", value: .count(1600), comparisonValue: .count(1300), change: -5)]
        let merged = TrendDeltas.apply(to: main, from: Overview(stats: delta))
        #expect(merged[0].value == .count(1600))
        #expect(merged[0].comparisonValue == .count(1300))
        #expect(merged[0].change == -5)
    }

    @Test("reload fetches a previous-period trend only without comparison")
    func trendOrchestration() async throws {
        let recorder = Recorder()
        let model = OverviewModel(
            overviewLoader: await recorder.overviewLoader(),
            seriesLoader: await recorder.seriesLoader()
        )
        try await model.reload(query: baseQuery(), today: frozenToday)
        let trendQuery = try #require((await recorder.overviewQueries).first { $0.comparison == .previousPeriod })
        #expect(trendQuery.period == .days28)
        if case .loaded = model.dashboard.trend.state {} else {
            Issue.record("trend should load")
        }
        let comparing = baseQuery()
        let onQuery = DashboardQuery(
            accountID: comparing.accountID, siteID: comparing.siteID, period: comparing.period,
            comparison: .previousPeriod, filters: comparing.filters, includeImported: comparing.includeImported,
            interval: comparing.interval, selectedMetric: comparing.selectedMetric, timeZone: comparing.timeZone
        )
        let before = await recorder.overviewQueries.count
        try await model.reload(query: onQuery, today: frozenToday)
        #expect(await recorder.overviewQueries.count == before + 1)
    }

    @Test("realtime skips the trend fetch")
    func realtimeSkipsTrend() async throws {
        let recorder = Recorder()
        let model = OverviewModel(
            overviewLoader: await recorder.overviewLoader(),
            seriesLoader: await recorder.seriesLoader()
        )
        let base = baseQuery()
        let realtime = DashboardQuery(
            accountID: base.accountID, siteID: base.siteID, period: .realtime,
            comparison: .off, filters: base.filters, includeImported: base.includeImported,
            interval: base.interval, selectedMetric: base.selectedMetric, timeZone: base.timeZone
        )
        try await model.reload(query: realtime, today: frozenToday)
        #expect(await recorder.overviewQueries.count == 1)
        if case .idle = model.dashboard.trend.state {} else {
            Issue.record("trend should stay idle for realtime")
        }
    }
}
