import AnalyticsCore
import Foundation

/// One known instance account. Nonsecret only: the session itself stays in
/// the Keychain (phase 03.3) and never enters these refs.
public struct AccountRef: Hashable, Sendable {
    public let id: AccountID
    public let baseURL: URL
    public let email: String?

    public init(id: AccountID, baseURL: URL, email: String? = nil) {
        self.id = id
        self.baseURL = baseURL
        self.email = email
    }

    public var displayName: String {
        email ?? baseURL.host() ?? baseURL.absoluteString
    }
}

/// One selectable site: dashboard domain plus team/role context from discovery.
public struct SiteRef: Hashable, Sendable {
    public let domain: String
    public let teamID: String?
    public let teamName: String?
    public let role: String?

    public init(domain: String, teamID: String? = nil, teamName: String? = nil, role: String? = nil) {
        self.domain = domain
        self.teamID = teamID
        self.teamName = teamName
        self.role = role
    }

    /// Sidebar grouping label. Never empty; unknown teams share one section.
    public var section: String { teamName ?? teamID ?? "Sites" }
}

/// Source of accounts and their sites. Production wiring (SessionCoordinator +
/// discovery, phase 03) lands with the app-target linking follow-on; shells
/// and tests inject fakes through this boundary. Client contracts unchanged.
public protocol SiteDirectory: Sendable {
    func accounts() async -> [AccountRef]
    func sites(for account: AccountRef) async throws -> [SiteRef]
}

/// No instances configured. Renders the honest empty state, never fake sites.
public struct EmptySiteDirectory: SiteDirectory, Sendable {
    public init() {}
    public func accounts() async -> [AccountRef] { [] }
    public func sites(for account: AccountRef) async throws -> [SiteRef] { [] }
}

/// Deterministic directory for UI tests and previews. Never ships real data.
public struct MockSiteDirectory: SiteDirectory, Sendable {
    private let storedAccounts: [AccountRef]
    private let storedSites: [AccountID: [SiteRef]]
    private let failureMessage: String?

    public init(accounts: [AccountRef], sites: [AccountID: [SiteRef]], failureMessage: String? = nil) {
        self.storedAccounts = accounts
        self.storedSites = sites
        self.failureMessage = failureMessage
    }

    public func accounts() async -> [AccountRef] { storedAccounts }

    public func sites(for account: AccountRef) async throws -> [SiteRef] {
        if let failureMessage { throw ReportLoadError(message: failureMessage, kind: .server) }
        return storedSites[account.id] ?? []
    }

    /// 2 instances; the first holds 13 sites across 2 teams with one very
    /// long domain, exercising the >12-site/long-name gate deterministically.
    public static func thirteenSites() -> MockSiteDirectory {
        let first = AccountRef(
            id: AccountID(),
            baseURL: URL(string: "https://stats.example.com")!,
            email: "owner@example.com"
        )
        let second = AccountRef(
            id: AccountID(),
            baseURL: URL(string: "https://localhost:8000")!,
            email: "viewer@example.com"
        )
        var sites: [SiteRef] = (1 ... 6).map { index in
            SiteRef(domain: "alpha-\(index).example.com", teamID: "team-alpha", teamName: "Alpha", role: index == 1 ? "owner" : "editor")
        }
        sites.append(SiteRef(
            domain: "extremely-long-subdomain-name-for-truncation-testing-purposes.example.com",
            teamID: "team-alpha",
            teamName: "Alpha",
            role: "viewer"
        ))
        sites += (1 ... 6).map { index in
            SiteRef(domain: "beta-\(index).example.org", teamID: "team-beta", teamName: "Beta", role: "viewer")
        }
        return MockSiteDirectory(
            accounts: [first, second],
            sites: [first.id: sites, second.id: [SiteRef(domain: "local.example", role: "owner")]]
        )
    }
}

/// Per-window selection state: instance, team/site, and the window's query.
/// Each window owns its own instance, so selections and queries never leak
/// across windows. Site list loading is explicit (loading/sites/error) and a
/// failed reload never clears the last good list.
@MainActor
@Observable
public final class SiteSelectionModel {
    public private(set) var accounts: [AccountRef] = []
    public var selectedAccountID: AccountID?
    public private(set) var sites: [SiteRef] = []
    public private(set) var sitesLoading = false
    public private(set) var sitesError: ReportLoadError?
    public var selectedDomain: String?
    /// Widget target being resolved while the account's site directory loads.
    public private(set) var pendingSiteDomain: String?
    /// The window's query, rebuilt from the default template on every site
    /// selection. Period/metric controls (04.3) edit a copy, never this.
    public private(set) var query: DashboardQuery?
    /// First directory load finished (sites known, restore attempted).
    /// Views show a boot shimmer until this flips, never a premature
    /// empty picker.
    public private(set) var booted = false

    private let directory: SiteDirectory
    private let pinned: PinnedSites
    private let preferences: SitePreferences

    public init(
        directory: SiteDirectory,
        pinned: PinnedSites = PinnedSites(),
        preferences: SitePreferences = SitePreferences()
    ) {
        self.directory = directory
        self.pinned = pinned
        self.preferences = preferences
    }

    public var selectedAccount: AccountRef? {
        accounts.first { $0.id == selectedAccountID }
    }

    public var selectedSite: SiteRef? {
        guard let selectedDomain else { return nil }
        return sites.first { $0.domain == selectedDomain }
    }

    /// Sites grouped for sidebar sections, in first-seen team order.
    public var siteSections: [(name: String, sites: [SiteRef])] {
        var order: [String] = []
        var grouped: [String: [SiteRef]] = [:]
        for site in sites {
            if grouped[site.section] == nil { order.append(site.section) }
            grouped[site.section, default: []].append(site)
        }
        return order.map { (name: $0, sites: grouped[$0] ?? []) }
    }

    /// Pinned sites for the selected account, in pin order.
    public var pinnedSites: [SiteRef] {
        let byDomain = Dictionary(uniqueKeysWithValues: sites.map { ($0.domain, $0) })
        return pinnedOrder.compactMap { byDomain[$0] }
    }

    /// Pin order mirror (observable; the store itself doesn't publish).
    public private(set) var pinnedOrder: [String] = []

    public func isPinned(_ domain: String) -> Bool {
        pinnedOrder.contains(domain)
    }

    public func setPinned(_ domain: String, pinned: Bool) {
        guard let account = selectedAccount else { return }
        self.pinned.setPinned(pinned, domain: domain, account: account.id)
        refreshPinnedOrder()
    }

    private func refreshPinnedOrder() {
        guard let account = selectedAccount else {
            pinnedOrder = []
            return
        }
        let known = Set(sites.map(\.domain))
        pinnedOrder = pinned.pinnedDomains(account: account.id).filter { known.contains($0) }
    }

    public func loadAccounts() async {
        defer { booted = true }
        let loaded = await directory.accounts()
        accounts = loaded
        if selectedAccountID == nil, await restoreLastSite(from: loaded) {
            return
        }
        if selectedAccountID == nil {
            selectedAccountID = loaded.first?.id
        } else if loaded.allSatisfy({ $0.id != selectedAccountID }) {
            selectedAccountID = loaded.first?.id
            clearSiteSelection()
        }
        await reloadSites()
    }

    public func selectAccount(_ id: AccountID?) async {
        guard id != selectedAccountID else { return }
        selectedAccountID = id
        clearSiteSelection()
        await reloadSites()
    }

    public func selectSite(_ domain: String?) {
        selectedDomain = domain
        query = defaultQuery()
        if let domain, let account = selectedAccount {
            preferences.saveLastSite(account: account.id, domain: domain)
        }
    }

    /// Selects the exact site encoded by a widget tap after account/site
    /// discovery has completed. Returns false if the identity is stale.
    @discardableResult
    public func openSite(accountID: AccountID, domain: String) async -> Bool {
        guard accounts.contains(where: { $0.id == accountID }) else { return false }
        pendingSiteDomain = domain
        defer { pendingSiteDomain = nil }
        if selectedAccountID != accountID {
            selectedAccountID = accountID
            clearSiteSelection()
            await reloadSites()
        } else if !sites.contains(where: { $0.domain == domain }) {
            await reloadSites()
        }
        guard sites.contains(where: { $0.domain == domain }) else { return false }
        selectSite(domain)
        return true
    }

    public func retrySites() async {
        await reloadSites()
    }

    /// Reopens the last active site when it still exists. Mock
    /// directories mint fresh account IDs per launch, so this path only
    /// ever fires against stable production identities.
    private func restoreLastSite(from loaded: [AccountRef]) async -> Bool {
        guard let last = preferences.lastSite(),
              let account = loaded.first(where: { $0.id.rawValue == last.account }),
              let sites = try? await directory.sites(for: account),
              sites.contains(where: { $0.domain == last.domain })
        else { return false }
        selectedAccountID = account.id
        self.sites = sites
        sitesError = nil
        sitesLoading = false
        refreshPinnedOrder()
        selectSite(last.domain)
        return true
    }

    // MARK: - Internals

    private func reloadSites() async {
        guard let account = selectedAccount else {
            sites = []
            sitesError = nil
            sitesLoading = false
            return
        }
        sitesLoading = true
        sitesError = nil
        do {
            let loaded = try await directory.sites(for: account)
            sites = loaded
            sitesError = nil
            if let selectedDomain, loaded.allSatisfy({ $0.domain != selectedDomain }) {
                clearSiteSelection()
            }
        } catch {
            sitesError = error as? ReportLoadError ?? ReportLoadError.wrap(error)
        }
        sitesLoading = false
        refreshPinnedOrder()
    }

    private func clearSiteSelection() {
        selectedDomain = nil
        query = nil
    }

    private func defaultQuery() -> DashboardQuery? {
        guard let account = selectedAccount, let site = selectedSite else { return nil }
        return DashboardQuery(
            accountID: account.id,
            siteID: SiteID(domain: site.domain, teamID: site.teamID),
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
