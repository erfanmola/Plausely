import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

private struct CannedTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> Data
    func send(_ request: URLRequest, expecting: ContentKind = .json) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (try handler(request), response)
    }
}

private func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

private func testQuery() -> DashboardQuery {
    DashboardQuery(
        accountID: AccountID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
        siteID: SiteID(domain: "shop.plausely.test"),
        period: .day,
        interval: .hour,
        selectedMetric: .visitors,
        timeZone: TimeZone(identifier: "Asia/Tehran")!
    )
}

private func testStack(handler: @escaping @Sendable (URLRequest) throws -> Data) -> CE321DashboardAdapter {
    let creds = FakeCredentialStore2()
    let dir = FileManager.default.temporaryDirectory.appending(path: "plausely-ad-\(UUID().uuidString)")
    let coordinator = SessionCoordinator(
        bridge: FakeBridge2(), credentials: creds,
        accounts: AccountStore(directory: dir), transport: CannedTransport(handler: { _ in Data() })
    )
    return CE321DashboardAdapter(coordinator: coordinator, transport: CannedTransport(handler: handler))
}

private struct FakeBridge2: WebLoginBridge {
    func loginCookies(email: String, password: String) async throws -> [HTTPCookie] { [] }
}

private struct FakeCredentialStore2: CredentialStore {
    final class Box: @unchecked Sendable {
        var credential = SessionCredential(
            baseURL: URL(string: "http://localhost:8000")!,
            cookies: [CookieRecord(name: "k", value: "v", domain: "localhost", path: "/", secure: false, httpOnly: false)],
            retrievedAt: Date()
        )
    }
    let box = Box()
    func load(for account: AccountID) async throws -> SessionCredential? { box.credential }
    func save(_ credential: SessionCredential, for account: AccountID) async throws { box.credential = credential }
    func remove(for account: AccountID) async throws {}
}

@Suite("dashboard adapter")
struct AdapterTests {
    @Test("overview maps values, warnings, and identity")
    func overview() async throws {
        let service = testStack { _ in try fixtureData("top-stats.day") }
        let envelope = try await service.overview(testQuery(), today: Date())
        #expect(envelope.value.stats.count == 6)
        #expect(envelope.value.stats[0].value == .count(1600))
        #expect(envelope.warnings.map(\.code) == ["imports-skipped"])
        #expect(!envelope.queryID.rawValue.isEmpty)
    }

    @Test("series preserves buckets and comparison")
    func series() async throws {
        let service = testStack { _ in try fixtureData("main-graph.sample") }
        let envelope = try await service.series(testQuery(), today: Date())
        #expect(envelope.value.labels == ["2026-09-20", "2026-09-21"])
        #expect(envelope.value.plot[1] == nil)
        #expect(envelope.value.comparisonPlot?.count == 2)
    }

    @Test("breakdown maps rows and survives unknown metric keys")
    func breakdown() async throws {
        let service = testStack { _ in try fixtureData("sources.day") }
        let request = BreakdownRequest(query: testQuery(), kind: .sources, pagination: .default, detailed: true)
        let envelope = try await service.breakdown(request, today: Date())
        #expect(!envelope.value.rows.isEmpty)
        #expect(envelope.value.rows[0].metrics[.visitors] != nil)
    }

    @Test("unknown graph metric fails loudly")
    func unknownMetric() async throws {
        let service = testStack { _ in try fixtureData("sources.day") }
        let request = BreakdownRequest(query: testQuery(), kind: .sources)
        // sources fixture has no graph_metric; force via overview on bad payload
        let bad = Data(#"{"meta":{"imports_included":true},"graphable_metrics":[],"top_stats":[{"name":"X","value":1,"graph_metric":"nope"}]}"#.utf8)
        let service2 = testStack { _ in bad }
        await #expect(throws: ClientError.self) {
            try await service2.overview(testQuery(), today: Date())
        }
        _ = request
    }

    @Test("query strings carry the full dashboard contract")
    func queryStrings() throws {
        let base = testQuery()
        let today = Date(timeIntervalSince1970: 1_759_000_000)
        let items = try CE321DashboardAdapter.queryItems(for: base, today: today)
        let names = items.map(\.name)
        #expect(names.contains("period") && names.contains("filters") && names.contains("interval") == false)
        let custom = DashboardQuery(
            accountID: base.accountID, siteID: base.siteID,
            period: .custom(from: Date(timeIntervalSince1970: 1_750_000_000), to: Date(timeIntervalSince1970: 1_750_100_000)),
            comparison: .previousPeriod, filters: base.filters, includeImported: true,
            interval: .day, selectedMetric: .visitors, timeZone: base.timeZone
        )
        let customItems = try CE321DashboardAdapter.queryItems(for: custom, today: today)
        let customNames = customItems.map(\.name)
        for required in ["from", "to", "comparison", "match_day_of_week", "with_imported"] {
            #expect(customNames.contains(required), "missing \(required)")
        }
    }
}
