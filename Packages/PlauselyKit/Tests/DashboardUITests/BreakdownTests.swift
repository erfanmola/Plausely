import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@MainActor
private func breakdownQuery() -> DashboardQuery {
    DashboardQuery(
        accountID: AccountID(),
        siteID: SiteID(domain: "shop.example"),
        period: .days28,
        comparison: .off,
        filters: .empty,
        includeImported: false,
        interval: .day,
        selectedMetric: .visitors,
        timeZone: TimeZone(identifier: "UTC")!
    )
}

private let frozenToday = Date(timeIntervalSince1970: 1_790_000_000)

private actor BreakdownScript {
    var requests: [BreakdownRequest] = []
    var failNext = false

    func loader() -> BreakdownModel.Loader {
        { request, today in
            await self.record(request)
            if await self.takeFailure() {
                throw ReportLoadError(message: "boom", kind: .server)
            }
            return try await MockBreakdownProviders.loader(request, today)
        }
    }

    private func record(_ request: BreakdownRequest) { requests.append(request) }
    private func takeFailure() -> Bool {
        defer { failNext = false }
        return failNext
    }

    func armFailure() { failNext = true }
}

@Suite("breakdown infrastructure (05.1)")
@MainActor
struct BreakdownTests {
    @Test("initial load serves page one with completeness")
    func initialLoad() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        #expect(model.rows.count == 10)
        #expect(model.page == 1)
        #expect(model.hasMore)
        #expect(model.completeness == (10, true))
        if case .loaded = model.state {} else { Issue.record("should be loaded") }
        let first = try await script.requests
        #expect(first.count == 1)
        #expect(first[0].pagination.page == 1 && first[0].pagination.limit == 10)
        #expect(first[0].sort == nil && first[0].search == nil)
    }

    @Test("load-more accumulates 1500 rows; empty last page closes without loss")
    func pagination() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 100,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        for _ in 1...15 { await model.loadMore(today: frozenToday) }
        #expect(model.rows.count == 1500)
        #expect(model.hasMore == false)
        #expect(model.completeness == (1500, false))
        #expect(model.rows.last?.name == "Source 1500")
    }

    @Test("sort goes server-side and resets to page one")
    func sortReloads() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        let naturalFirst = try #require(model.rows.first?.name)
        await model.setSort(ReportSort(key: .metric(.visitors), direction: .ascending), today: frozenToday)
        #expect(model.page == 1)
        #expect(model.rows.count == 10)
        #expect(model.rows.first?.name != naturalFirst)
        let requests = await script.requests
        #expect(requests.last?.sort == ReportSort(key: .metric(.visitors), direction: .ascending))
        #expect(requests.last?.pagination.page == 1)
        // Same sort re-applied issues no new request.
        await model.setSort(ReportSort(key: .metric(.visitors), direction: .ascending), today: frozenToday)
        #expect(await script.requests.count == requests.count)
    }

    @Test("ties keep served order: the model never re-sorts")
    func tiesStable() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 21,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        let expected = MockBreakdownProviders.dataset().prefix(21).map(\.name)
        #expect(model.rows.map(\.name) == expected)
    }

    @Test("search filters server-side when supported, ignored otherwise")
    func searchSupport() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        await model.setSearch("0001", today: frozenToday)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.name == "Source 0001")
        #expect(model.hasMore == false)
        let plain = ReportDefinition(kind: .sources, title: "Sources", columns: [.visitors])
        let script2 = BreakdownScript()
        let model2 = BreakdownModel(
            definition: plain, query: breakdownQuery(), pageSize: 10,
            loader: await script2.loader()
        )
        await model2.load(today: frozenToday)
        await model2.setSearch("0001", today: frozenToday)
        #expect(model2.search == nil)
        #expect(model2.rows.count == 10)
        #expect(await script2.requests.count == 1)
    }

    @Test("mock honors query filters like a filtered drilldown")
    func mockQueryFilters() async throws {
        let script = BreakdownScript()
        let base = breakdownQuery()
        let filtered = DashboardQuery(
            accountID: base.accountID,
            siteID: base.siteID,
            period: base.period,
            comparison: base.comparison,
            filters: FilterExpression(clauses: [
                FilterClause(dimension: .source, op: .is_, values: [.text("0001")])
            ]),
            includeImported: base.includeImported,
            interval: base.interval,
            selectedMetric: base.selectedMetric,
            timeZone: base.timeZone
        )
        let loader = await script.loader()
        let envelope = try await loader(
            BreakdownRequest(query: filtered, kind: .sources, pagination: Pagination(limit: 9, page: 1)),
            frozenToday
        )
        #expect(envelope.value.rows.map(\.name) == ["Source 0001"])
    }

    @Test("failure keeps prior rows; retry continues paging")
    func failureAndRetry() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: await script.loader()
        )
        await script.armFailure()
        await model.load(today: frozenToday)
        if case .failed = model.state {} else { Issue.record("should be failed") }
        #expect(model.rows.isEmpty)
        await model.retry(today: frozenToday)
        #expect(model.rows.count == 10)
        await script.armFailure()
        await model.loadMore(today: frozenToday)
        #expect(model.rows.count == 10)
        if case .failed = model.state {} else { Issue.record("more-failure should surface") }
        await model.retry(today: frozenToday)
        #expect(model.rows.count == 20)
    }

    @Test("cancel keeps prior rows, idles an initial load")
    func cancelKeepsRows() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        #expect(model.rows.count == 10)
        await model.loadMore(today: frozenToday)
        #expect(model.rows.count == 20)

        let slow = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CancellationError()
            }
        )
        let task = Task { await slow.load(today: frozenToday) }
        await Task.yield()
        await Task.yield()
        slow.cancel()
        await task.value
        if case .idle = slow.state {} else { Issue.record("cancelled initial load should idle") }
        #expect(slow.rows.isEmpty)
    }

    @Test("comparison queries carry previous values and server deltas; off leaves none")
    func comparisonSynthesis() async throws {
        let off = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 3,
            loader: MockBreakdownProviders.loader
        )
        await off.load(today: frozenToday)
        #expect(off.rows.allSatisfy { $0.comparison == nil && $0.change.isEmpty })

        var compared = breakdownQuery()
        compared = DashboardQuery(
            accountID: compared.accountID,
            siteID: compared.siteID,
            period: .days7,
            comparison: .previousPeriod,
            filters: compared.filters,
            includeImported: compared.includeImported,
            interval: compared.interval,
            selectedMetric: compared.selectedMetric,
            timeZone: compared.timeZone
        )
        let on = BreakdownModel(
            definition: .sourcesProof, query: compared, pageSize: 3,
            loader: MockBreakdownProviders.loader
        )
        await on.load(today: frozenToday)
        let first = try #require(on.rows.first)
        let prev = try #require(first.comparison)
        #expect(prev[.visitors] != nil)
        #expect(first.change.keys.contains(.visitors))
        let delta: Int? = first.change[.visitors] ?? nil
        #expect(delta != nil)
    }

    @Test("change badges stay short with the full sentence for voice labels")
    func changeTextForms() {
        #expect(shortChangeText(100) == "▲ +100%")
        #expect(shortChangeText(-67) == "▼ -67%")
        #expect(shortChangeText(0) == "■ 0%")
        #expect(shortChangeText(nil) == nil)
        #expect(changeText(100) == "▲ +100% vs comparison")
    }

    @Test("identical query retarget is a no-op; changed query reloads")
    func updateQuery() async throws {
        let script = BreakdownScript()
        let model = BreakdownModel(
            definition: .sourcesProof, query: breakdownQuery(), pageSize: 10,
            loader: await script.loader()
        )
        await model.load(today: frozenToday)
        let same = model.query
        await model.updateQuery(same, today: frozenToday)
        #expect(await script.requests.count == 1)
        var changed = same
        changed = DashboardQuery(
            accountID: changed.accountID,
            siteID: changed.siteID,
            period: .days7,
            comparison: changed.comparison,
            filters: changed.filters,
            includeImported: changed.includeImported,
            interval: changed.interval,
            selectedMetric: changed.selectedMetric,
            timeZone: changed.timeZone
        )
        await model.updateQuery(changed, today: frozenToday)
        #expect(await script.requests.count == 2)
        #expect(model.rows.count == 10)
    }
}
