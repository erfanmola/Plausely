import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

/// Toggleable directory proving failed reloads keep the last good list.
private actor FlakyStore {
    var fail = false
    let account = AccountRef(id: AccountID(), baseURL: URL(string: "https://stats.example.com")!, email: "owner@example.com")
    let sites = [SiteRef(domain: "kept.example.com", teamID: "t1", teamName: "One", role: "owner")]
}

private struct FlakyDirectory: SiteDirectory, Sendable {
    let store: FlakyStore
    func accounts() async -> [AccountRef] { [await store.account] }
    func sites(for account: AccountRef) async throws -> [SiteRef] {
        if await store.fail { throw ReportLoadError(message: "offline", kind: .network) }
        return await store.sites
    }
}

@Suite("site selection shells (04.2)")
@MainActor
struct SiteSelectionTests {
    private let frozenToday = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("first account and its sites load by default")
    func defaultAccount() async {
        let model = SiteSelectionModel(directory: MockSiteDirectory.thirteenSites())
        await model.loadAccounts()
        #expect(model.accounts.count == 2)
        #expect(model.selectedAccount?.email == "owner@example.com")
        #expect(model.sites.count == 13)
        #expect(model.sitesError == nil)
    }

    @Test("sites group into team sections in first-seen order")
    func teamSections() async {
        let model = SiteSelectionModel(directory: MockSiteDirectory.thirteenSites())
        await model.loadAccounts()
        let sections = model.siteSections
        #expect(sections.map(\.name) == ["Alpha", "Beta"])
        #expect(sections[0].sites.count == 7)
        #expect(sections[1].sites.count == 6)
    }

    @Test("selecting a site builds the window default query")
    func siteQuery() async throws {
        let model = SiteSelectionModel(directory: MockSiteDirectory.thirteenSites())
        await model.loadAccounts()
        model.selectSite("beta-3.example.org")
        let query = try #require(model.query)
        #expect(query.siteID.domain == "beta-3.example.org")
        #expect(query.siteID.teamID == "team-beta")
        #expect(query.period == .days28)
        #expect(query.selectedMetric == .visitors)
        #expect(query.timeZone.secondsFromGMT(for: frozenToday) == 0)
        #expect(query.accountID == model.selectedAccount?.id)
    }

    @Test("switching accounts clears the site and query, then loads its sites")
    func accountSwitch() async throws {
        let model = SiteSelectionModel(directory: MockSiteDirectory.thirteenSites())
        await model.loadAccounts()
        model.selectSite("alpha-1.example.com")
        #expect(model.query != nil)
        let second = try #require(model.accounts.last?.id)
        await model.selectAccount(second)
        #expect(model.selectedDomain == nil)
        #expect(model.query == nil)
        #expect(model.sites.map(\.domain) == ["local.example"])
    }

    @Test("selecting a site that vanished clears the query")
    func vanishedSite() async {
        let store = FlakyStore()
        let model = SiteSelectionModel(directory: FlakyDirectory(store: store))
        await model.loadAccounts()
        model.selectSite("kept.example.com")
        #expect(model.query != nil)
        model.selectSite("gone.example.com")
        #expect(model.selectedSite == nil)
        #expect(model.query == nil)
    }

    @Test("failed reload keeps the last good list with a retryable error")
    func failedReloadKeepsList() async {
        let store = FlakyStore()
        let model = SiteSelectionModel(directory: FlakyDirectory(store: store))
        await model.loadAccounts()
        #expect(model.sites.count == 1)
        await store.setFail()
        await model.retrySites()
        #expect(model.sites.map(\.domain) == ["kept.example.com"])
        #expect(model.sitesError?.message == "offline")
        #expect(model.sitesLoading == false)
    }

    @Test("windows stay independent: selections and queries never cross")
    func windowIsolation() async throws {
        let directory = MockSiteDirectory.thirteenSites()
        let first = SiteSelectionModel(directory: directory)
        let second = SiteSelectionModel(directory: directory)
        await first.loadAccounts()
        await second.loadAccounts()
        first.selectSite("alpha-1.example.com")
        second.selectSite("beta-1.example.org")
        #expect(first.query?.siteID.domain == "alpha-1.example.com")
        #expect(second.query?.siteID.domain == "beta-1.example.org")
        let secondAccount = try #require(second.accounts.last?.id)
        await second.selectAccount(secondAccount)
        #expect(first.selectedAccount?.email == "owner@example.com")
        #expect(first.sites.count == 13)
        #expect(second.sites.map(\.domain) == ["local.example"])
    }

    @Test("empty directory renders no accounts and no error")
    func emptyDirectory() async {
        let model = SiteSelectionModel(directory: EmptySiteDirectory())
        await model.loadAccounts()
        #expect(model.accounts.isEmpty)
        #expect(model.sites.isEmpty)
        #expect(model.sitesError == nil)
        #expect(model.query == nil)
    }
}

private extension FlakyStore {
    func setFail() { fail = true }
}

@Suite("site pinning")
@MainActor
struct SitePinningTests {
    private func ephemeral() -> UserDefaults {
        let suite = UserDefaults(suiteName: "plausely-pin-tests")!
        suite.removePersistentDomain(forName: "plausely-pin-tests")
        return suite
    }

    @Test("pins persist per account in pin order")
    func pinRoundTrip() async {
        let store = PinnedSites(defaults: ephemeral())
        let directory = MockSiteDirectory.thirteenSites()
        let model = SiteSelectionModel(directory: directory, pinned: store)
        await model.loadAccounts()
        #expect(model.pinnedSites.isEmpty)
        model.setPinned("beta-2.example.org", pinned: true)
        model.setPinned("alpha-1.example.com", pinned: true)
        #expect(model.pinnedSites.map(\.domain) == ["beta-2.example.org", "alpha-1.example.com"])
        #expect(model.isPinned("alpha-1.example.com"))
        model.setPinned("beta-2.example.org", pinned: false)
        #expect(model.pinnedSites.map(\.domain) == ["alpha-1.example.com"])
        // A fresh model over the same directory and store sees the pins.
        let revived = SiteSelectionModel(directory: directory, pinned: store)
        await revived.loadAccounts()
        #expect(revived.pinnedSites.map(\.domain) == ["alpha-1.example.com"])
    }

    @Test("pins are isolated across accounts and drop vanished sites")
    func pinIsolation() async {
        let store = PinnedSites(defaults: ephemeral())
        let model = SiteSelectionModel(directory: MockSiteDirectory.thirteenSites(), pinned: store)
        await model.loadAccounts()
        model.setPinned("alpha-1.example.com", pinned: true)
        await model.selectAccount(model.accounts[1].id)
        #expect(model.pinnedSites.isEmpty)
        model.setPinned("local.example", pinned: true)
        #expect(model.pinnedSites.map(\.domain) == ["local.example"])
        await model.selectAccount(model.accounts[0].id)
        #expect(model.pinnedSites.map(\.domain) == ["alpha-1.example.com"])
    }
}

private struct StableDirectory: SiteDirectory, Sendable {
    let account = AccountRef(
        id: AccountID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
        baseURL: URL(string: "https://stats.example.com")!,
        email: "owner@example.com"
    )
    let sites = [
        SiteRef(domain: "one.example.com", teamID: "t", teamName: "T", role: "owner"),
        SiteRef(domain: "two.example.com", teamID: "t", teamName: "T", role: "owner"),
    ]
    func accounts() async -> [AccountRef] { [account] }
    func sites(for account: AccountRef) async throws -> [SiteRef] { sites }
}

@Suite("site preferences")
@MainActor
struct SitePreferencesTests {
    private func ephemeral() -> UserDefaults {
        let suite = UserDefaults(suiteName: "plausely-prefs-tests")!
        suite.removePersistentDomain(forName: "plausely-prefs-tests")
        return suite
    }

    @Test("controls round-trip through the store")
    func controlsRoundTrip() {
        let prefs = SitePreferences(defaults: ephemeral())
        let account = AccountID()
        let stored = StoredControls(period: "7d", comparison: "previous_period", matchDayOfWeek: false, includeImported: true)
        prefs.saveControls(stored, account: account, domain: "shop.example")
        #expect(prefs.controls(account: account, domain: "shop.example") == stored)
        #expect(prefs.controls(account: account, domain: "other.example") == nil)
    }

    @Test("unknown values degrade to safe defaults")
    func sanitize() {
        #expect(StoredControls(period: "nonsense").makePeriod() == .days28)
        #expect(StoredControls(period: "day", comparison: "previous_period").makeComparison(for: .realtime) == .off)
        #expect(StoredControls(period: "day", comparison: "bogus").makeComparison(for: .day) == .off)
        #expect(StoredControls(period: "custom").makePeriod() == .days28)
        let custom = StoredControls(period: "custom", customFrom: Date(timeIntervalSince1970: 100), customTo: Date(timeIntervalSince1970: 200))
        #expect(custom.makePeriod() == .custom(from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 200)))
    }

    @Test("last active site restores on launch when still present")
    func lastSiteRestore() async {
        let prefs = SitePreferences(defaults: ephemeral())
        let first = SiteSelectionModel(directory: StableDirectory(), preferences: prefs)
        await first.loadAccounts()
        #expect(first.selectedDomain == nil)
        first.selectSite("two.example.com")
        #expect(first.selectedDomain == "two.example.com")
        let revived = SiteSelectionModel(directory: StableDirectory(), preferences: prefs)
        await revived.loadAccounts()
        #expect(revived.selectedDomain == "two.example.com")
        #expect(revived.query?.siteID.domain == "two.example.com")
    }

    @Test("vanished last site falls back to no selection")
    func lastSiteVanished() async {
        struct EmptyStable: SiteDirectory, Sendable {
            let wrapped = StableDirectory()
            func accounts() async -> [AccountRef] { await [wrapped.account] }
            func sites(for account: AccountRef) async throws -> [SiteRef] { [] }
        }
        let prefs = SitePreferences(defaults: ephemeral())
        let first = SiteSelectionModel(directory: StableDirectory(), preferences: prefs)
        await first.loadAccounts()
        first.selectSite("two.example.com")
        let revived = SiteSelectionModel(directory: EmptyStable(), preferences: prefs)
        await revived.loadAccounts()
        #expect(revived.selectedDomain == nil)
    }

    @Test("query model applies stored controls")
    func applyStored() throws {
        let model = QueryModel(base: baseQueryLike(), intervalPolicy: MockQueryProviders.intervals)
        model.applyStored(StoredControls(period: "7d", comparison: "previous_period"))
        let query = try #require(model.effective)
        #expect(query.period == .days7)
        #expect(query.comparison == .previousPeriod)
        #expect(query.interval == .day)
    }

    private func baseQueryLike() -> DashboardQuery {
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
}
