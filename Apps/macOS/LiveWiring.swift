import AnalyticsCore
import DashboardUI
import Foundation
import PlausibleClient
import SwiftUI

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
    private let credentials = KeychainCredentialStore()
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
            return [SiteRef(domain: link.domain, role: "shared")]
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
        return refs.sorted { $0.domain < $1.domain }
    }

    func timeZone(account: AccountID, domain: String) async -> TimeZone? {
        bootstraps[account.rawValue.uuidString + "/" + domain]?.timeZone
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
                            .fill(
                                LinearGradient(
                                    colors: [.indigo, .blue],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
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
    @State private var queryModel: QueryModel?
    @State private var overviewModel: OverviewModel?
    @State private var channelsModel: BreakdownModel?
    @State private var sourcesModel: BreakdownModel?
    @State private var pagesModel: BreakdownModel?
    @State private var entryModel: BreakdownModel?
    @State private var exitModel: BreakdownModel?
    @State private var countriesModel: BreakdownModel?
    @State private var browsersModel: BreakdownModel?
    @State private var screensModel: BreakdownModel?
    @State private var systemsModel: BreakdownModel?
    @State private var goalsModel: BreakdownModel?
    @State private var realtimeModel = RealtimeModel()
    @State private var overviewOverviewCache = ReportCache<Overview>()
    @State private var overviewSeriesCache = ReportCache<TimeSeries>()
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
                NavigationSplitView {
                    SiteSidebarView(model: selection)
                } detail: {
                    SiteDetailView(
                        site: selection.selectedSite,
                        query: selection.query,
                        queryModel: queryModel,
                        overviewModel: overviewModel,
                        channelsModel: channelsModel,
                        sourcesModel: sourcesModel,
                        pagesModel: pagesModel,
                        entryModel: entryModel,
                        exitModel: exitModel,
                        countriesModel: countriesModel,
                        browsersModel: browsersModel,
                        screensModel: screensModel,
                        systemsModel: systemsModel,
                        goalsModel: goalsModel,
                        breakdownChild: liveChild(),
                        onBreakdownFilter: { [queryModel] clause in queryModel?.addClause(clause) ?? false },
                        realtimeModel: realtimeModel,
                        onExport: { [hub] query in
                            let result = try await hub.export(query, today: Date())
                            return (filename: result.filename, data: result.data)
                        },
                    )
                    .toolbar {
                        if let account = selection.selectedAccount {
                            Button("Sign Out") {
                                Task { await signOut(account) }
                            }
                            .accessibilityIdentifier("live-signout")
                        }
                    }
                }
                .onChange(of: selection.query) { _, query in
                    Task { await rebuildModels(for: query) }
                }
                .onChange(of: queryModel?.effective) {
                    updateRealtimeTick()
                }
            }
        }
        .task { await refreshAccounts() }
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

    /// Rebuilds every report model for the selected query with live loaders.
    /// Applies the site's IANA timezone (settings transport) before the first
    /// load so day boundaries match the dashboard; unknown timezone keeps the
    /// model's own default rather than the device zone.
    private func rebuildModels(for query: DashboardQuery?) async {
        guard let query else {
            queryModel = nil
            overviewModel = nil
            channelsModel = nil
            sourcesModel = nil
            pagesModel = nil
            entryModel = nil
            exitModel = nil
            countriesModel = nil
            browsersModel = nil
            screensModel = nil
            systemsModel = nil
            goalsModel = nil
            realtimeModel.stop()
            realtimeModel.onTick = nil
            return
        }
        let effective = await corrected(query)
        let hub = hub
        queryModel = QueryModel(
            base: effective,
            suggestions: { request, today in
                let results = try await hub.suggestions(request, today: today)
                return results.map { Suggestion(label: $0.label, value: $0.value) }
            },
            segmentList: nil
        )
        // Shared-link locked scope: the server's segment id becomes the
        // immutable lock (cleared only by signing out). The lock rides
        // every query and can never be broadened from the filter editor.
        if let segment = await hub.limitedSegment(accountID: effective.accountID) {
            queryModel?.locked = FilterExpression(clauses: [
                FilterClause(dimension: .segment, op: .is_, values: [.number(segment)])
            ])
            queryModel?.refresh()
        }
        overviewModel = OverviewModel(
            overviewLoader: { query, today in try await hub.overview(query, today: today) },
            seriesLoader: { query, today in try await hub.series(query, today: today) },
            overviewCache: overviewOverviewCache,
            seriesCache: overviewSeriesCache
        )
        sourcesModel = liveBreakdown(.sources, query: effective, hub: hub)
        channelsModel = liveBreakdown(.channels, query: effective, hub: hub)
        pagesModel = liveBreakdown(.pages, query: effective, hub: hub)
        entryModel = liveBreakdown(.entryPages, query: effective, hub: hub)
        exitModel = liveBreakdown(.exitPages, query: effective, hub: hub)
        countriesModel = liveBreakdown(.countries, query: effective, hub: hub)
        browsersModel = liveBreakdown(.browsers, query: effective, hub: hub)
        screensModel = liveBreakdown(.screenSizes, query: effective, hub: hub)
        systemsModel = liveBreakdown(.operatingSystems, query: effective, hub: hub)
        goalsModel = liveBreakdown(.conversions, query: effective, hub: hub)
        realtimeModel.start(account: effective.accountID, site: effective.siteID) { account, site in
            try await hub.currentVisitors(accountID: account, domain: site.domain)
        }
        updateRealtimeTick()
    }

    private func liveBreakdown(
        _ definition: ReportDefinition, query: DashboardQuery, hub: LiveHub
    ) -> BreakdownModel {
        BreakdownModel(
            definition: definition, query: query,
            loader: { request, today in try await hub.breakdown(request, today: today) }
        )
    }

    /// Arms the realtime-period refresh: on the dashboard's realtime query
    /// every headcount tick also reloads the visible reports. Historical
    /// periods keep the badge polling but never touch reports.
    private func updateRealtimeTick() {
        guard let effective = queryModel?.effective, effective.period == .realtime else {
            realtimeModel.onTick = nil
            return
        }
        realtimeModel.onTick = { [queryModel, overviewModel, channelsModel, sourcesModel, pagesModel, entryModel, exitModel, countriesModel, browsersModel, screensModel, systemsModel, goalsModel] in
            guard let current = queryModel?.effective else { return }
            await overviewModel?.reload(query: current)
            await channelsModel?.load()
            await sourcesModel?.load()
            await pagesModel?.load()
            await entryModel?.load()
            await exitModel?.load()
            await countriesModel?.load()
            await browsersModel?.load()
            await screensModel?.load()
            await systemsModel?.load()
            await goalsModel?.load()
        }
    }

    private func liveChild() -> BreakdownChildFactory {
        let hub = hub
        return { target, query in
            BreakdownModel(
                definition: breakdownDefinition(for: target.kind, title: target.title),
                query: breakdownQuery(query, adding: target.filter),
                loader: { request, today in try await hub.breakdown(request, today: today) }
            )
        }
    }

    private func corrected(_ query: DashboardQuery) async -> DashboardQuery {
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
}
