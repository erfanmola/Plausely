import AnalyticsCore
import DashboardUI
import Foundation
import PlausibleClient
import SwiftUI
import WidgetKit

/// v1 live wiring (04.2 follow-on). App targets link PlausibleClient and
/// compose the productized session/discovery/adapter graph here; DashboardUI
/// stays transport-free and receives only loader closures plus a live
/// `SiteDirectory`. Mock mode is untouched for deterministic UI tests.
///
/// NOTE (both platforms): `Apps/iOS/LiveWiring.swift` and
/// `Apps/macOS/LiveWiring.swift` are intentionally identical. Keep them in
/// sync; the only per-platform code lives in the `*App.swift` roots.

// MARK: - Errors

enum LiveError: LocalizedError {
    case noStorage
    case badServerURL(String)
    case badSharedLink

    var errorDescription: String? {
        switch self {
        case .noStorage:
            return "Device storage is unavailable, so the instance cannot be saved."
        case .badServerURL(let text):
            return "“\(text)” is not a valid server URL (for example https://stats.example.com)."
        case .badSharedLink:
            return "That doesn't look like a shared dashboard link (it needs ?auth=)."
        }
    }
}

// MARK: - Hub

/// Sendable live-service hub. One per window; persistence (account records in
/// Application Support, session secrets in the Keychain) is shared, so a
/// login in one window is visible to windows opened afterwards.
actor LiveHub {
    private let transport = URLSessionTransport()
    private let credentials = KeychainCredentialStore(
        accessGroup: Bundle.main.infoDictionary?["PlauselyKeychainAccessGroup"] as? String
    )
    private let store: AccountStore?
    private var contexts: [AccountID: LiveContext] = [:]
    /// Shared-link adapters (slug auth, no session) by account.
    private var sharedAdapters: [AccountID: CE321DashboardAdapter] = [:]
    /// Locked shared-link segment ids by account, from the share bootstrap.
    private var limitedSegments: [AccountID: Int] = [:]
    /// Bootstrap cache for role/team/timezone without refetching per report.
    private var bootstraps: [String: SiteBootstrap] = [:]

    init() {
        self.store = try? AccountStore.production()
    }

    // MARK: Accounts

    func accountRefs() -> [AccountRef] {
        guard let store else { return [] }
        let ids = (try? store.allIDs()) ?? []
        return ids.compactMap { id in
            guard let record = try? store.load(id: id) else { return nil }
            return AccountRef(id: record.id, baseURL: record.baseURL, email: record.email)
        }
        .sorted { $0.displayName < $1.displayName }
    }

    /// Interactive login through the productized coordinator path: isolated
    /// webview sign-in, session secret to the Keychain, nonsecret record to
    /// Application Support. Passwords never persist anywhere.
    func login(baseURLText: String, email: String, password: String) async throws -> AccountRef {
        guard let store else { throw LiveError.noStorage }
        let baseURL = try Self.normalizeServerURL(baseURLText)
        _ = try RequestBuilder(baseURL: baseURL)
        let account = AccountID()
        let coordinator = SessionCoordinator(
            bridge: WebAuthenticationBridge(baseURL: baseURL),
            credentials: credentials,
            accounts: store,
            transport: transport
        )
        // The bridge interaction hops to the main actor internally; the
        // coordinator persists the credential and account record itself.
        _ = try await coordinator.login(account: account, baseURL: baseURL, email: email, password: password)
        contexts[account] = LiveContext(
            coordinator: coordinator,
            discovery: CE321SiteDiscovery(coordinator: coordinator, transport: transport),
            adapter: CE321DashboardAdapter(coordinator: coordinator, transport: transport)
        )
        guard let record = try? store.load(id: account) else {
            throw LiveError.noStorage
        }
        return AccountRef(id: record.id, baseURL: record.baseURL, email: record.email)
    }

    /// Passwordless shared-link access (SHARE-01, read-only). Verifies the
    /// slug against the share bootstrap before saving anything; locked
    /// segment scope is enforced on every query through `limitedSegment`.
    /// Password-protected links fail typed (no dashboard container) and are
    /// never attempted silently.
    func loginSharedLink(urlText: String) async throws -> AccountRef {
        guard let store else { throw LiveError.noStorage }
        guard let (baseURL, link) = SharedLinkRef.parse(urlText) else {
            throw LiveError.badSharedLink
        }
        _ = try RequestBuilder(baseURL: baseURL)
        let shared = try await CE321SharedDiscovery(transport: transport)
            .bootstrap(baseURL: baseURL, domain: link.domain, slug: link.slug)
        let account = AccountID()
        try store.save(AccountRecord(id: account, baseURL: baseURL, email: nil, sharedLink: link))
        sharedAdapters[account] = CE321DashboardAdapter(
            coordinator: SessionCoordinator(
                bridge: WebAuthenticationBridge(baseURL: baseURL),
                credentials: credentials, accounts: store, transport: transport
            ),
            transport: transport,
            sharedBase: baseURL, sharedAuth: link.slug
        )
        bootstraps[account.rawValue.uuidString + "/" + link.domain] = SiteBootstrap(
            snapshot: shared.snapshot, timeZone: nil
        )
        if let segment = shared.limitedSegmentID {
            limitedSegments[account] = segment
        }
        return AccountRef(id: account, baseURL: baseURL, email: nil)
    }

    /// Locked shared-link segment id, if the share bootstrap carries one.
    /// Re-fetched on demand so the lock survives app restarts. Roots apply
    /// it as the immutable query lock.
    func limitedSegment(accountID: AccountID) async -> Int? {
        if let cached = limitedSegments[accountID] { return cached }
        guard let store,
              let record = try? store.load(id: accountID),
              let link = record.sharedLink,
              let shared = try? await CE321SharedDiscovery(transport: transport)
                .bootstrap(baseURL: record.baseURL, domain: link.domain, slug: link.slug)
        else { return nil }
        limitedSegments[accountID] = shared.limitedSegmentID
        return shared.limitedSegmentID
    }

    /// Full sign-out: server logout best-effort, then secret + record removal
    /// so the sidebar returns to the honest no-instance state.
    func signOut(_ id: AccountID) async throws {
        if let context = contexts[id] {
            try? await context.coordinator.logout(account: id)
            contexts[id] = nil
        } else if let store, let record = try? store.load(id: id) {
            let coordinator = SessionCoordinator(
                bridge: WebAuthenticationBridge(baseURL: record.baseURL),
                credentials: credentials,
                accounts: store, transport: transport
            )
            try? await coordinator.logout(account: id)
        }
        try? await credentials.remove(for: id)
        if let store {
            try? store.remove(id: id)
        }
        bootstraps = bootstraps.filter { !$0.key.hasPrefix(id.rawValue.uuidString + "/") }
        sharedAdapters[id] = nil
        limitedSegments[id] = nil
        WidgetSiteCatalog.remove(accountID: id)
    }

    // MARK: Sites

    /// Test-only reset (gated on the `-plausely-live-reset` launch argument
    /// by the caller): removes every stored record and session secret so UI
    /// tests start from the honest no-instance state. Never called otherwise.
    func resetForTesting() async {
        guard let store else { return }
        for id in (try? store.allIDs()) ?? [] {
            try? await credentials.remove(for: id)
            try? store.remove(id: id)
        }
        contexts = [:]
        bootstraps = [:]
    }
    func sites(for account: AccountRef) async throws -> [SiteRef] {
        // Shared links expose exactly their linked site (verified at login).
        if let store, let record = try? store.load(id: account.id), let link = record.sharedLink {
            let site = SiteRef(domain: link.domain, role: "shared")
            WidgetSiteCatalog.replace(accountID: account.id, with: [
                WidgetSiteOption(accountID: account.id, domain: site.domain, teamID: nil, timeZoneID: nil)
            ])
            return [site]
        }
        let context = try contextFor(account: account)
        let domains = try await context.discovery.discover(account: account.id)
        // Per-site bootstrap supplies role/team/timezone; one failure never
        // drops the domain (role/team stay nil, timezone falls back later).
        var refs: [SiteRef] = []
        await withTaskGroup(of: SiteRef.self) { group in
            for domain in domains.map(\.domain) {
                group.addTask {
                    do {
                        let bootstrap = try await self.bootstrap(account: account, domain: domain)
                        return SiteRef(
                            domain: domain,
                            teamID: bootstrap.snapshot.teamIdentifier,
                            role: bootstrap.snapshot.currentUserRole
                        )
                    } catch {
                        return SiteRef(domain: domain)
                    }
                }
            }
            for await ref in group {
                refs.append(ref)
            }
        }
        let sorted = refs.sorted { $0.domain < $1.domain }
        WidgetSiteCatalog.replace(accountID: account.id, with: sorted.map { site in
            WidgetSiteOption(
                accountID: account.id,
                domain: site.domain,
                teamID: site.teamID,
                timeZoneID: bootstraps[account.id.rawValue.uuidString + "/" + site.domain]?.timeZone?.identifier
            )
        })
        return sorted
    }

    func timeZone(account: AccountID, domain: String) async -> TimeZone? {
        let key = account.rawValue.uuidString + "/" + domain
        if let cached = bootstraps[key] { return cached.timeZone }
        // Site discovery bootstraps sites concurrently. A selection can be
        // restored while that first pass is still in flight, so resolve the
        // timezone on demand instead of letting Today query in GMT.
        guard let store, let record = try? store.load(id: account) else { return nil }
        let ref = AccountRef(id: record.id, baseURL: record.baseURL, email: record.email)
        return try? await bootstrap(account: ref, domain: domain).timeZone
    }

    /// Bootstrap interval map for one site (nil until discovered).
    func intervals(account: AccountID, domain: String) async -> IntervalPolicy? {
        bootstraps[account.rawValue.uuidString + "/" + domain]?.snapshot.intervals
    }

    func currentVisitors(accountID: AccountID, domain: String) async throws -> Int {
        try await adapterFor(accountID: accountID)
            .currentVisitors(account: accountID, site: SiteID(domain: domain))
            .count
    }

    func export(_ query: DashboardQuery, today: Date) async throws -> DashboardExport {
        try await adapterFor(accountID: query.accountID).export(query, today: today)
    }

    // MARK: Reports

    func overview(_ query: DashboardQuery, today: Date) async throws -> ReportEnvelope<Overview> {
        try await adapterFor(accountID: query.accountID).overview(query, today: today)
    }

    func series(_ query: DashboardQuery, today: Date) async throws -> ReportEnvelope<TimeSeries> {
        try await adapterFor(accountID: query.accountID).series(query, today: today)
    }

    func breakdown(_ request: BreakdownRequest, today: Date) async throws -> ReportEnvelope<BreakdownPage> {
        try await adapterFor(accountID: request.query.accountID).breakdown(request, today: today)
    }

    func suggestions(_ request: SuggestionRequest, today: Date) async throws -> [FilterSuggestion] {
        try await adapterFor(accountID: request.query.accountID).suggestions(request, today: today)
    }

    // MARK: Internals

    private struct LiveContext: Sendable {
        let coordinator: SessionCoordinator
        let discovery: CE321SiteDiscovery
        let adapter: CE321DashboardAdapter
    }

    private func contextFor(account: AccountRef) throws -> LiveContext {
        if let context = contexts[account.id] { return context }
        guard let store else { throw LiveError.noStorage }
        let coordinator = SessionCoordinator(
            bridge: WebAuthenticationBridge(baseURL: account.baseURL),
            credentials: credentials,
            accounts: store, transport: transport
        )
        let context = LiveContext(
            coordinator: coordinator,
            discovery: CE321SiteDiscovery(coordinator: coordinator, transport: transport),
            adapter: CE321DashboardAdapter(coordinator: coordinator, transport: transport)
        )
        contexts[account.id] = context
        return context
    }

    private func adapterFor(accountID: AccountID) throws -> CE321DashboardAdapter {
        if let context = contexts[accountID] { return context.adapter }
        if let shared = sharedAdapters[accountID] { return shared }
        guard let store else { throw LiveError.noStorage }
        guard let record = try? store.load(id: accountID) else {
            throw SessionCoordinator.SessionError.unknownAccount
        }
        let coordinator = SessionCoordinator(
            bridge: WebAuthenticationBridge(baseURL: record.baseURL),
            credentials: credentials,
            accounts: store, transport: transport
        )
        if let link = record.sharedLink {
            let adapter = CE321DashboardAdapter(
                coordinator: coordinator, transport: transport,
                sharedBase: record.baseURL, sharedAuth: link.slug
            )
            sharedAdapters[accountID] = adapter
            return adapter
        }
        let context = LiveContext(
            coordinator: coordinator,
            discovery: CE321SiteDiscovery(coordinator: coordinator, transport: transport),
            adapter: CE321DashboardAdapter(coordinator: coordinator, transport: transport)
        )
        contexts[accountID] = context
        return context.adapter
    }

    private func bootstrap(account: AccountRef, domain: String) async throws -> SiteBootstrap {
        let key = account.id.rawValue.uuidString + "/" + domain
        if let cached = bootstraps[key] { return cached }
        let fetched = try await contextFor(account: account).discovery.bootstrap(account: account.id, domain: domain)
        bootstraps[key] = fetched
        return fetched
    }

    /// Accepts bare hosts (`stats.example.com`) by assuming https; loopback
    /// http stays allowed for local evaluation servers.
    private static func normalizeServerURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LiveError.badServerURL(text) }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        guard let url = URL(string: "https://" + trimmed), url.host != nil else {
            throw LiveError.badServerURL(text)
        }
        return url
    }
}

// MARK: - Directory

/// Live `SiteDirectory` over the hub: accounts from the on-disk record store,
/// sites from dashboard discovery. No fake data; empty means no instances.
struct LiveSiteDirectory: SiteDirectory, Sendable {
    let hub: LiveHub
    func accounts() async -> [AccountRef] {
        await hub.accountRefs()
    }
    func sites(for account: AccountRef) async throws -> [SiteRef] {
        try await hub.sites(for: account)
    }
}

// MARK: - Login

/// First-run sign-in. Passwords stay in the secure field and the isolated
/// webview; only first-party session cookies persist (Keychain).
struct LoginView: View {
    let hub: LiveHub
    var onLogin: () -> Void
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var useSharedLink = false
    @State private var sharedURL = ""

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: 76, height: 76)
                        Image(systemName: "chart.bar.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                    Text("Welcome to Plausely")
                        .font(.title2)
                        .bold()
                    Text("Sign in to your analytics instance to browse sites and reports.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("Instance") {
                Toggle("Use a shared link instead", isOn: $useSharedLink)
                    .accessibilityIdentifier("login-shared-toggle")
                if useSharedLink {
                    TextField("Shared link (…/share/site?auth=…)", text: $sharedURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .accessibilityIdentifier("login-shared-url")
                } else {
                    TextField("Server (https://stats.example.com)", text: $server)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                    .accessibilityIdentifier("login-server")
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .accessibilityIdentifier("login-email")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("login-password")
                }
            }
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("login-error")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Section {
                Button(busy ? "Signing in…" : (useSharedLink ? "Open Shared View" : "Sign In")) {
                    Task { await signIn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || (useSharedLink ? sharedURL.isEmpty : (server.isEmpty || email.isEmpty || password.isEmpty)))
                .accessibilityIdentifier("login-submit")
                .animation(.snappy, value: busy)
            }
        }
        .frame(maxWidth: 620)
        .navigationTitle("Sign In")
        .accessibilityIdentifier("login-view")
        .animation(.snappy, value: message)
    }

    private func signIn() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            if useSharedLink {
                _ = try await hub.loginSharedLink(urlText: sharedURL)
                onLogin()
                return
            }
            _ = try await hub.login(baseURLText: server, email: email, password: password)
            password = ""
            onLogin()
        } catch is CancellationError {
            message = "Sign-in was cancelled."
        } catch let failure as LiveError {
            message = failure.localizedDescription
        } catch BridgeError.twoFactorRequired {
            message = "This account needs two-factor authentication, which sign-in here doesn't support yet."
        } catch BridgeError.invalidCredentials {
            message = "Wrong email or password."
        } catch BridgeError.timedOut {
            message = "The server took too long to respond. Try again."
        } catch ClientError.loginRequired {
            message = "Wrong email or password."
        } catch ClientError.siteUnavailable {
            message = "The server refused this request. Check the address and try again."
        } catch {
            message = "Sign-in failed. Check the server address and connection."
        }
    }
}

// MARK: - Root

/// Live per-window root: login gate, then the shared sidebar/detail shells
/// with productized loaders. Mirrors the mock root's model construction; only
/// the loaders, directory, and timezone correction differ.
struct LiveRootView: View {
    private let hub = LiveHub()
    @State private var directory: LiveSiteDirectory
    @State private var selection: SiteSelectionModel
    @State private var accounts: [AccountRef] = []
    @State private var accountsLoaded = false
    @State private var widgetDestination: WidgetSiteDestination?
    @State private var signOutError: String?
    @State private var showingSignOutError = false

    init() {
        let hub = self.hub
        let directory = LiveSiteDirectory(hub: hub)
        _directory = State(initialValue: directory)
        _selection = State(initialValue: SiteSelectionModel(directory: directory))
    }

    var body: some View {
        Group {
            if !accountsLoaded {
                ProgressView("Loading instances…")
                    .accessibilityIdentifier("live-loading")
            } else if accounts.isEmpty {
                NavigationStack {
                    LoginView(hub: hub) {
                        Task { await refreshAccounts() }
                    }
                }
            } else {
                HomeRootView(
                    directory: directory,
                    overviewLoader: { [hub] query, today in try await hub.overview(query, today: today) },
                    seriesLoader: { [hub] query, today in try await hub.series(query, today: today) },
                    breakdownLoader: { [hub] request, today in try await hub.breakdown(request, today: today) },
                    suggestions: { [hub] request, today in
                        let results = try await hub.suggestions(request, today: today)
                        return results.map { Suggestion(label: $0.label, value: $0.value) }
                    },
                    segmentList: nil,
                    realtimeLoader: { [hub] account, site in
                        try await hub.currentVisitors(accountID: account, domain: site.domain)
                    },
                    onSignOut: { account in
                        try await hub.signOut(account.id)
                        await refreshAccounts()
                    },
                    onExport: { [hub] query in
                        let result = try await hub.export(query, today: Date())
                        return (filename: result.filename, data: result.data)
                    },
                    resolveBase: { [hub] query in await corrected(query, hub: hub) },
                    applyLock: { [hub] queryModel in
                        if let segment = await hub.limitedSegment(accountID: queryModel.base.accountID) {
                            queryModel.locked = FilterExpression(clauses: [
                                FilterClause(dimension: .segment, op: .is_, values: [.number(segment)])
                            ])
                            queryModel.refresh()
                        }
                    },
                    resolvePolicy: { [hub] query in
                        await hub.intervals(account: query.accountID, domain: query.siteID.domain)
                    },
                    sparkline: { [hub] site, account in
                        let preview = DashboardQuery(
                            accountID: account,
                            siteID: SiteID(domain: site.domain, teamID: site.teamID),
                            period: .days28,
                            comparison: .off,
                            filters: .empty,
                            includeImported: false,
                            interval: .day,
                            selectedMetric: .visitors,
                            timeZone: TimeZone(identifier: "UTC")!
                        )
                        let fixed = await corrected(preview, hub: hub)
                        return try? await hub.series(fixed, today: Date()).value
                    },
                    widgetDestination: widgetDestination,
                    onWidgetDestinationHandled: { widgetDestination = nil }
                )
            }
        }
        .task { await refreshAccounts() }
        .onOpenURL { url in widgetDestination = WidgetSiteDestination(url: url) }
        .alert("Couldn't sign out", isPresented: $showingSignOutError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(signOutError ?? "")
        }
    }

    // MARK: Wiring

    private func refreshAccounts() async {
        if CommandLine.arguments.contains("-plausely-live-reset") {
            await hub.resetForTesting()
        }
        accounts = await hub.accountRefs()
        accountsLoaded = true
        await selection.loadAccounts()
        WidgetCenter.shared.reloadTimelines(ofKind: "PlauselyAnalyticsWidget")
    }

    private func signOut(_ account: AccountRef) async {
        do {
            try await hub.signOut(account.id)
            signOutError = nil
            await refreshAccounts()
        } catch {
            signOutError = "The instance couldn't be removed. Try again."
            showingSignOutError = true
        }
    }
}

private func corrected(_ query: DashboardQuery, hub: LiveHub) async -> DashboardQuery {
    guard let zone = await hub.timeZone(account: query.accountID, domain: query.siteID.domain),
          zone != query.timeZone
    else { return query }
    return DashboardQuery(
        accountID: query.accountID,
        siteID: query.siteID,
        period: query.period,
        periodDate: query.periodDate,
        comparison: query.comparison,
        matchDayOfWeek: query.matchDayOfWeek,
        filters: query.filters,
        includeImported: query.includeImported,
        interval: query.interval,
        selectedMetric: query.selectedMetric,
        timeZone: zone
    )
}
