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
