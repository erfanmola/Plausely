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
        // No comparison query, no comparison payload.
        #expect(envelope.value.rows[0].comparison == nil)
    }

    @Test("breakdown maps nested comparison values and server change percents")
    func breakdownComparison() async throws {
        let service = testStack { _ in try fixtureData("sources.comparison-day") }
        let request = BreakdownRequest(query: testQuery(), kind: .sources, pagination: .default, detailed: true)
        let envelope = try await service.breakdown(request, today: Date())
        let google = try #require(envelope.value.rows.first)
        #expect(google.name == "Google")
        #expect(google.metrics[.visitors] == .count(2))
        let comparison = try #require(google.comparison)
        #expect(comparison[.visitors] == .count(0))
        // Server null durations stay unavailable gaps, never zeros.
        #expect(comparison[.visitDuration] == .unavailable(.null))
        #expect(google.change[.visitors] == 100)
        // Explicit server null change is preserved as a present key with
        // a nil delta (subscript yields a double optional; flatten it).
        #expect(google.change.keys.contains(.bounceRate))
        let bounceDelta: Int? = google.change[.bounceRate] ?? nil
        #expect(bounceDelta == nil)
        let duck = try #require(envelope.value.rows.last)
        #expect(duck.change[.percentage] == -67)
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

    @Test("referrer drilldown decodes URLs with engagement columns")
    func referrerDrilldown() async throws {
        let service = testStack { _ in try fixtureData("referrers.drill") }
        let request = BreakdownRequest(
            query: testQuery(),
            kind: .referrerDrilldown(referrer: "newsletter"),
            pagination: .default, detailed: true
        )
        let envelope = try await service.breakdown(request, today: Date())
        #expect(envelope.value.rows.count == 4)
        #expect(envelope.value.rows[1].name == "bing.com/search")
        #expect(envelope.value.rows[1].metrics[.visitors] == .count(46))
        #expect(envelope.value.rows[1].metrics[.bounceRate] == .count(100))
        #expect(envelope.value.rows[1].metrics[.visitDuration] == .count(0))
        #expect(envelope.value.rows[1].metrics[.percentage] != nil)
    }

    @Test("each UTM route decodes its own family with engagement columns")
    func utmFamilies() async throws {
        let cases: [(ReportKind, String, String)] = [
            (.utmMediums, "utm_mediums.day", "email"),
            (.utmSources, "utm_sources.day", "newsletter"),
            (.utmCampaigns, "utm_campaigns.day", "launch"),
            (.utmTerms, "utm_terms.day", "a"),
            (.utmContents, "utm_contents.day", "top"),
        ]
        for (kind, fixture, name) in cases {
            let service = testStack { _ in try fixtureData(fixture) }
            let envelope = try await service.breakdown(
                BreakdownRequest(query: testQuery(), kind: kind, pagination: .default, detailed: true),
                today: Date()
            )
            #expect(envelope.value.rows.count == 1, "\(kind)")
            #expect(envelope.value.rows[0].name == name, "\(kind)")
            #expect(envelope.value.rows[0].metrics[.visitors] == .count(200), "\(kind)")
            #expect(envelope.value.rows[0].metrics[.bounceRate] == .count(100), "\(kind)")
            #expect(envelope.value.rows[0].metrics[.visitDuration] == .count(0), "\(kind)")
        }
    }

    @Test("pages decode engagement conditionals; entrances/exits stay distinct")
    func pageFamilies() async throws {
        let pages = testStack { _ in try fixtureData("pages.detailed") }
        let pageEnvelope = try await pages.breakdown(
            BreakdownRequest(query: testQuery(), kind: .pages, pagination: .default, detailed: true),
            today: Date()
        )
        let home = try #require(pageEnvelope.value.rows.first)
        #expect(home.name == "/")
        #expect(home.metrics[.visitors] == .count(450))
        #expect(home.metrics[.pageviews] == .count(450))
        #expect(home.metrics[.timeOnPage] == .unavailable(.null))
        #expect(home.metrics[.scrollDepth] == .unavailable(.null))

        let entries = testStack { _ in try fixtureData("entry-pages.day") }
        let entryEnvelope = try await entries.breakdown(
            BreakdownRequest(query: testQuery(), kind: .entryPages, pagination: .default, detailed: true),
            today: Date()
        )
        let entryHome = try #require(entryEnvelope.value.rows.first)
        #expect(entryHome.metrics[.visits] == .count(450))
        #expect(entryHome.metrics[.pageviews] == nil)

        let exits = testStack { _ in try fixtureData("exit-pages.day") }
        let exitEnvelope = try await exits.breakdown(
            BreakdownRequest(query: testQuery(), kind: .exitPages, pagination: .default, detailed: true),
            today: Date()
        )
        let exitHome = try #require(exitEnvelope.value.rows.first)
        #expect(exitHome.metrics[.visits] == .count(450))
        #expect(exitHome.metrics[.exitRate] != nil)
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

    @Test("geo families decode codes, names, and share without engagement")
    func geoFamilies() async throws {
        // Countries carry ISO codes + flag; only visitors/share are metrics
        // (pinned upstream countries_test.exs:19-36).
        let countries = testStack { _ in try fixtureData("countries.day") }
        let countryEnvelope = try await countries.breakdown(
            BreakdownRequest(query: testQuery(), kind: .countries, pagination: .default, detailed: true),
            today: Date()
        )
        let estonia = try #require(countryEnvelope.value.rows.first)
        #expect(estonia.name == "Estonia")
        #expect(estonia.code == "EE")
        #expect(estonia.flag == "🇪🇪")
        #expect(estonia.metrics[.visitors] == .count(2))
        #expect(estonia.metrics[.percentage] == .decimal(Decimal(string: "66.67")!))
        #expect(estonia.metrics[.bounceRate] == nil)

        // Regions carry subdivision codes (pinned upstream regions_test.exs:40-55).
        let regions = testStack { _ in try fixtureData("regions.day") }
        let regionEnvelope = try await regions.breakdown(
            BreakdownRequest(query: testQuery(), kind: .regions, pagination: .default, detailed: true),
            today: Date()
        )
        let harjumaa = try #require(regionEnvelope.value.rows.first)
        #expect(harjumaa.name == "Harjumaa")
        #expect(harjumaa.code == "EE-37")

        // City geoname IDs arrive as integers and stringify instead of
        // failing the row (pinned upstream cities_test.exs:40-55).
        let cities = testStack { _ in try fixtureData("cities.day") }
        let cityEnvelope = try await cities.breakdown(
            BreakdownRequest(query: testQuery(), kind: .cities, pagination: .default, detailed: true),
            today: Date()
        )
        let tallinn = try #require(cityEnvelope.value.rows.first)
        #expect(tallinn.name == "Tallinn")
        #expect(tallinn.code == "588409")
        #expect(tallinn.flag == "🇪🇪")
        #expect(tallinn.metrics[.visitors] == .count(3))
    }

    @Test("device families decode engagement conditionals per route")
    func deviceFamilies() async throws {
        // Live-shaped browsers: name + share only, no engagement keys.
        let browsers = testStack { _ in try fixtureData("browsers.day") }
        let browserEnvelope = try await browsers.breakdown(
            BreakdownRequest(query: testQuery(), kind: .browsers, pagination: .default, detailed: true),
            today: Date()
        )
        let chrome = try #require(browserEnvelope.value.rows.first)
        #expect(chrome.name == "Chrome")
        #expect(chrome.metrics[.visitors] == .count(658))
        #expect(chrome.metrics[.bounceRate] == nil)
        #expect(chrome.metrics[.visitDuration] == nil)

        // Detailed version rows use version-only names with engagement
        // (pinned upstream browsers_test.exs:468-492).
        let versions = testStack { _ in try fixtureData("browser-versions.day") }
        let versionEnvelope = try await versions.breakdown(
            BreakdownRequest(query: testQuery(), kind: .browserVersions, pagination: .default, detailed: true),
            today: Date()
        )
        let v78 = try #require(versionEnvelope.value.rows.first)
        #expect(v78.name == "78.0")
        #expect(v78.metrics[.bounceRate] == .count(100))
        #expect(v78.metrics[.visitDuration] == .count(0))

        // Detailed screens add engagement (pinned upstream
        // screen_sizes_test.exs:38-59).
        let screens = testStack { _ in try fixtureData("screen-sizes.day") }
        let screenEnvelope = try await screens.breakdown(
            BreakdownRequest(query: testQuery(), kind: .screenSizes, pagination: .default, detailed: true),
            today: Date()
        )
        let desktop = try #require(screenEnvelope.value.rows.first)
        #expect(desktop.metrics[.bounceRate] == .count(50))
        #expect(desktop.metrics[.visitDuration] == .count(300))

        let systems = testStack { _ in try fixtureData("operating-systems.day") }
        let systemEnvelope = try await systems.breakdown(
            BreakdownRequest(query: testQuery(), kind: .operatingSystems, pagination: .default, detailed: true),
            today: Date()
        )
        #expect(try #require(systemEnvelope.value.rows.first).name == "Mac")

        let osVersions = testStack { _ in try fixtureData("operating-system-versions.day") }
        let osVersionEnvelope = try await osVersions.breakdown(
            BreakdownRequest(query: testQuery(), kind: .operatingSystemVersions, pagination: .default, detailed: true),
            today: Date()
        )
        let v14 = try #require(osVersionEnvelope.value.rows.first)
        #expect(v14.name == "14")
        #expect(v14.metrics[.bounceRate] == .count(100))
    }

    @Test("conversions decode uniques, totals, and rates")
    func goalConversions() async throws {
        let goals = testStack { _ in try fixtureData("conversions.day") }
        let envelope = try await goals.breakdown(
            BreakdownRequest(query: testQuery(), kind: .conversions, pagination: .default, detailed: true),
            today: Date()
        )
        let signup = try #require(envelope.value.rows.first)
        #expect(signup.name == "Signup")
        #expect(signup.metrics[.visitors] == .count(200))
        #expect(signup.metrics[.events] == .count(200))
        #expect(signup.metrics[.conversionRate] == .decimal(Decimal(string: "12.5")!))
        #expect(envelope.value.rows.count == 2)
    }

    @Test("property values decode shares and keep (none) rows")
    func propValues() async throws {
        let props = testStack { _ in try fixtureData("custom-props.day") }
        let envelope = try await props.breakdown(
            BreakdownRequest(
                query: testQuery(), kind: .customPropValues(key: "variant"),
                pagination: .default, detailed: true
            ),
            today: Date()
        )
        #expect(envelope.value.rows.count == 2)
        #expect(envelope.value.rows[0].metrics[.events] == .count(2))
        #expect(envelope.value.rows[1].name == "(none)")
    }

    @Test("breakdown import-exclusion reasons surface as warnings")
    func breakdownImportWarnings() async throws {
        let service = testStack { _ in
            Data(#"{"results":[],"skip_imported_reason":"unsupported_query"}"#.utf8)
        }
        let envelope = try await service.breakdown(
            BreakdownRequest(query: testQuery(), kind: .sources, pagination: .default, detailed: true),
            today: Date()
        )
        #expect(envelope.value.rows.isEmpty)
        #expect(envelope.warnings == [ReportWarning(
            code: "imports-skipped",
            message: "Imported stats are not included in the results because query parameters are not supported."
        )])
    }

    @Test("export filenames parse from content-disposition, never guessed")
    func exportFilenames() {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(
                url: URL(string: "https://stats.example.com/shop/export")!,
                statusCode: 200, httpVersion: nil, headerFields: headers
            )!
        }
        #expect(CE321DashboardAdapter.exportFilename(from: response([
            "Content-Disposition": "attachment; filename=\"Plausible export shop 2026-10-05 to 2026-10-05 .zip\"",
        ])) == "Plausible export shop 2026-10-05 to 2026-10-05 .zip")
        #expect(CE321DashboardAdapter.exportFilename(from: response([:])) == nil)
        #expect(CE321DashboardAdapter.exportFilename(from: response([
            "Content-Disposition": "attachment",
        ])) == nil)
    }

    @Test("export requires ZIP magic and carries the server filename")
    func exportPayload() async throws {
        struct PathCheck: Error {}
        let service = testStack {
            guard $0.url?.path.hasSuffix("/shop.plausely.test/export") == true else { throw PathCheck() }
            guard ($0.url?.query ?? "").contains("interval=") else { throw PathCheck() }
            return Data([0x50, 0x4B, 0x03, 0x04, 0x00])
        }
        // Canned transport has no content-disposition: default filename.
        let result = try await service.export(testQuery(), today: Date())
        #expect(result.filename == "plausely-export.zip")
        #expect(result.data.starts(with: [0x50, 0x4B]))
    }
}
