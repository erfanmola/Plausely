import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

private actor LoaderScript {
    var calls: [String] = []
    var delayByDomain: [String: UInt64] = [:]
    var failDomains: Set<String> = []
    var visitorCount: Int = 10

    func loader() -> ReportModel<Overview>.Loader {
        { query, today in
            await self.record(query.siteID.domain)
            if let delay = await self.delay(for: query.siteID.domain) {
                try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            if await self.shouldFail(query.siteID.domain) {
                throw ReportLoadError(message: "boom", kind: .server)
            }
            let id = try QueryID.compute(for: query, today: today)
            let count = await self.count()
            return ReportEnvelope(
                queryID: id,
                value: Overview(stats: [
                    TopStat(metric: query.selectedMetric, name: "Visitors", value: .count(Int64(count)))
                ]),
                retrievedAt: today
            )
        }
    }

    private func record(_ domain: String) { calls.append(domain) }
    private func delay(for domain: String) -> UInt64? { delayByDomain[domain] }
    private func shouldFail(_ domain: String) -> Bool { failDomains.contains(domain) }
    private func count() -> Int { visitorCount }

    func callCount(for domain: String) -> Int { calls.filter { $0 == domain }.count }
    var totalCalls: Int { calls.count }
    func setDelay(_ ns: UInt64, for domain: String) { delayByDomain[domain] = ns }
    func setFail(_ domain: String) { failDomains.insert(domain) }
    func setCount(_ value: Int) { visitorCount = value }
}

@MainActor
private func makeQuery(account: AccountID, domain: String, metric: MetricID = .visitors) -> DashboardQuery {
    DashboardQuery(
        accountID: account,
        siteID: SiteID(domain: domain),
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

@Suite("report lifecycle (04.1)")
@MainActor
struct ReportLifecycleTests {
    @Test("delayed A cannot overwrite newer B")
    func delayedADiscarded() async throws {
        let script = LoaderScript()
        await script.setDelay(120_000_000, for: "a.example")
        let model = ReportModel<Overview>(loader: await script.loader())
        let account = AccountID()
        let queryA = makeQuery(account: account, domain: "a.example")
        let queryB = makeQuery(account: account, domain: "b.example")

        let taskA = Task { await model.load(query: queryA, today: frozenToday) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.load(query: queryB, today: frozenToday)
        await taskA.value

        let expectedB = try QueryID.compute(for: queryB, today: frozenToday)
        #expect(model.queryID == expectedB)
        if case .loaded(let envelope) = model.state {
            #expect(envelope.value.stats.first?.value == .count(10))
        } else {
            Issue.record("expected loaded B, got \(model.state)")
        }
        // B's envelope must carry B's identity, never A's.
        #expect(model.state.displayable?.queryID == expectedB)
    }

    @Test("concurrent loads of the same query deduplicate to one fetch")
    func dedupSameQuery() async {
        let script = LoaderScript()
        let model = ReportModel<Overview>(loader: await script.loader())
        let query = makeQuery(account: AccountID(), domain: "same.example")

        async let first: () = model.load(query: query, today: frozenToday)
        async let second: () = model.load(query: query, today: frozenToday)
        await first
        await second

        #expect(await script.totalCalls == 1)
        if case .loaded = model.state {} else {
            Issue.record("expected loaded, got \(model.state)")
        }
    }

    @Test("manual refresh while loading the same query is deduplicated")
    func dedupRefresh() async throws {
        let script = LoaderScript()
        await script.setDelay(80_000_000, for: "slow.example")
        let model = ReportModel<Overview>(loader: await script.loader())
        let query = makeQuery(account: AccountID(), domain: "slow.example")

        let task = Task { await model.load(query: query, today: frozenToday) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await model.refresh(today: frozenToday)
        await task.value

        #expect(await script.totalCalls == 1)
    }

    @Test("refresh keeps the old value visible as stale, then publishes new")
    func staleRefresh() async throws {
        let script = LoaderScript()
        let model = ReportModel<Overview>(loader: await script.loader())
        let query = makeQuery(account: AccountID(), domain: "stale.example")

        await script.setCount(10)
        await model.load(query: query, today: frozenToday)
        #expect(model.state.displayable?.value.stats.first?.value == .count(10))

        await script.setCount(99)
        await script.setDelay(80_000_000, for: "stale.example")
        let task = Task { await model.refresh(today: frozenToday) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(model.state.isLoading)
        #expect(model.state.displayable?.value.stats.first?.value == .count(10))
        await task.value
        #expect(model.state.displayable?.value.stats.first?.value == .count(99))
        if case .loaded = model.state {} else {
            Issue.record("expected loaded after refresh, got \(model.state)")
        }
    }

    @Test("failed refresh keeps the previous value as stale, not erased")
    func failedRefreshKeepsStale() async {
        let script = LoaderScript()
        let model = ReportModel<Overview>(loader: await script.loader())
        let query = makeQuery(account: AccountID(), domain: "flaky.example")

        await script.setCount(7)
        await model.load(query: query, today: frozenToday)
        #expect(model.state.displayable?.value.stats.first?.value == .count(7))

        await script.setFail("flaky.example")
        await model.refresh(today: frozenToday)
        if case .failed(let error, let stale) = model.state {
            #expect(error.message == "boom")
            #expect(stale?.value.stats.first?.value == .count(7))
        } else {
            Issue.record("expected failed-with-stale, got \(model.state)")
        }
        #expect(model.state.displayable?.value.stats.first?.value == .count(7))
    }

    @Test("cancellation never becomes an error banner")
    func cancelIsSilent() async throws {
        let script = LoaderScript()
        await script.setDelay(120_000_000, for: "cancel.example")
        let model = ReportModel<Overview>(loader: await script.loader())
        let query = makeQuery(account: AccountID(), domain: "cancel.example")

        let task = Task { await model.load(query: query, today: frozenToday) }
        try await Task.sleep(nanoseconds: 10_000_000)
        model.cancel()
        await task.value

        if case .failed = model.state {
            Issue.record("cancellation must not publish failure")
        }
        #expect(!model.state.isLoading)
    }

    @Test("cache isolates accounts and removal clears only that account")
    func cacheIsolation() async {
        let script = LoaderScript()
        let cache = ReportCache<Overview>(maxEntries: 10)
        let model = ReportModel<Overview>(loader: await script.loader(), cache: cache)
        let accountA = AccountID()
        let accountB = AccountID()
        let queryA = makeQuery(account: accountA, domain: "site.example")
        let queryB = makeQuery(account: accountB, domain: "site.example")

        await model.load(query: queryA, today: frozenToday)
        await model.load(query: queryB, today: frozenToday)
        #expect(await script.totalCalls == 2)

        await model.load(query: queryA, today: frozenToday)
        #expect(await script.totalCalls == 2) // cache hit, no fetch

        await cache.removeAll(for: accountA)
        await model.load(query: queryA, today: frozenToday)
        #expect(await script.totalCalls == 3)
        await model.load(query: queryB, today: frozenToday)
        #expect(await script.totalCalls == 3) // B's entry survived
    }

    @Test("bounded cache evicts the oldest entry")
    func boundedEviction() async throws {
        let cache = ReportCache<Overview>(maxEntries: 2)
        let account = AccountID()
        var ids: [QueryID] = []
        for domain in ["one.example", "two.example", "three.example"] {
            let query = makeQuery(account: account, domain: domain)
            let id = try QueryID.compute(for: query, today: frozenToday)
            ids.append(id)
            await cache.store(
                ReportEnvelope(queryID: id, value: Overview(stats: []), retrievedAt: frozenToday),
                account: account
            )
        }
        #expect(await cache.count == 2)
        #expect(await cache.envelope(for: ids[0]) == nil)
        #expect(await cache.envelope(for: ids[1]) != nil)
        #expect(await cache.envelope(for: ids[2]) != nil)
    }

    @Test("empty payload publishes empty, not a zero-filled value")
    func emptyState() async {
        let loader: ReportModel<Overview>.Loader = { query, today in
            let id = try QueryID.compute(for: query, today: today)
            return ReportEnvelope(queryID: id, value: Overview(stats: []), retrievedAt: today)
        }
        let model = ReportModel<Overview>(loader: loader, isEmpty: { $0.stats.isEmpty })
        await model.load(query: makeQuery(account: AccountID(), domain: "empty.example"), today: frozenToday)
        if case .empty = model.state {} else {
            Issue.record("expected empty, got \(model.state)")
        }
    }

    @Test("dashboard keeps the good report when its sibling fails")
    func independentFailure() async {
        let overviewLoader: ReportModel<Overview>.Loader = { _, _ in
            throw ReportLoadError(message: "overview down", kind: .server)
        }
        let seriesLoader: ReportModel<TimeSeries>.Loader = { query, today in
            let id = try QueryID.compute(for: query, today: today)
            return ReportEnvelope(
                queryID: id,
                value: TimeSeries(metric: .visitors, labels: ["2026-09-20"], plot: [.count(5)]),
                retrievedAt: today
            )
        }
        let dashboard = DashboardModel(overviewLoader: overviewLoader, seriesLoader: seriesLoader)
        await dashboard.load(query: makeQuery(account: AccountID(), domain: "mixed.example"), today: frozenToday)

        if case .failed(let error, _) = dashboard.overview.state {
            #expect(error.message == "overview down")
        } else {
            Issue.record("overview must fail, got \(dashboard.overview.state)")
        }
        if case .loaded(let envelope) = dashboard.series.state {
            #expect(envelope.value.plot == [.count(5)])
        } else {
            Issue.record("series must stay loaded, got \(dashboard.series.state)")
        }
    }

    @Test("unsupported publishes its own state, not a generic error")
    func unsupportedState() async {
        let script = LoaderScript()
        let model = ReportModel<Overview>(loader: await script.loader())
        model.publishUnsupported(reason: "needs configuration")
        if case .unsupported(let reason) = model.state {
            #expect(reason == "needs configuration")
        } else {
            Issue.record("expected unsupported, got \(model.state)")
        }
    }

    @Test("retry revalidates the same query")
    func retryReloads() async {
        let script = LoaderScript()
        let model = ReportModel<Overview>(loader: await script.loader())
        let query = makeQuery(account: AccountID(), domain: "retry.example")
        await model.load(query: query, today: frozenToday)
        await script.setCount(42)
        // No cache involved, so retry must fetch again.
        await model.retry(today: frozenToday)
        #expect(await script.totalCalls == 2)
        #expect(model.state.displayable?.value.stats.first?.value == .count(42))
    }
}

@Suite("error hygiene")
struct ErrorHygieneTests {
    @Test("decoder failures read as human sentences, never dumps")
    func decodingHuman() {
        struct Bad: Decodable { let required: Int }
        let failure: Error = {
            do {
                _ = try JSONDecoder().decode(Bad.self, from: Data("{}".utf8))
                fatalError("must throw")
            } catch {
                return error
            }
        }()
        let wrapped = ReportLoadError.wrap(failure)
        #expect(wrapped.kind == .server)
        #expect(!wrapped.message.contains("Path:"))
        #expect(!wrapped.message.contains("Debug description"))
    }

    @Test("transport failures read as human sentences")
    func transportHuman() {
        #expect(ReportLoadError.wrap(URLError(.timedOut)).message == "The server took too long to respond.")
        #expect(ReportLoadError.wrap(URLError(.notConnectedToInternet)).message == "No connection to the server.")
        #expect(ReportLoadError.wrap(URLError(.cannotFindHost)).kind == .network)
    }

    @Test("known errors pass through untouched")
    func passthrough() {
        let known = ReportLoadError(message: "boom", kind: .server)
        #expect(ReportLoadError.wrap(known).message == "boom")
    }
}
