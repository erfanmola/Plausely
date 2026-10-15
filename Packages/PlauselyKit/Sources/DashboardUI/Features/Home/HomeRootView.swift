import AnalyticsCore
import SwiftUI

/// Home root: pill header plus four tabs in the native tab bar (Liquid
/// Glass on current iOS, classic bar on older floors, native tabs on
/// macOS). Owns the window's selection and every report model; loaders
/// arrive injected so mock and live share every pixel on both platforms.
public struct HomeRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    public enum Tab: String, Hashable, CaseIterable {
        case overview, breakdowns, goals, settings
    }

    @State private var selection: SiteSelectionModel
    @State private var selectedTab: Tab = .overview
    @State private var queryModel: QueryModel?
    @State private var overviewModel: OverviewModel?
    @State private var realtimeModel = RealtimeModel()
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
    @State private var overviewOverviewCache = ReportCache<Overview>()
    @State private var overviewSeriesCache = ReportCache<TimeSeries>()

    private let directory: any SiteDirectory
    private let overviewLoader: ReportModel<Overview>.Loader
    private let seriesLoader: ReportModel<TimeSeries>.Loader
    private let breakdownLoader: BreakdownModel.Loader
    private let suggestions: SuggestionProvider?
    private let segmentList: SegmentListProvider?
    private let realtimeLoader: RealtimeModel.CountLoader
    private let onSignOut: (@MainActor (AccountRef) async throws -> Void)?
    private let onExport: ExportButton.Exporter?
    /// Live-only base rewrite (site timezone). Defaults to identity.
    private let resolveBase: (@MainActor (DashboardQuery) async -> DashboardQuery)?
    /// Live-only lock application (shared-link scope) on the fresh query
    /// model, before any report model builds from it.
    private let applyLock: (@MainActor (QueryModel) async -> Void)?
    /// Site bootstrap interval map for the query's site. The query model
    /// re-derives intervals on period changes (with an hourly Today chart),
    /// so a stale interval never reaches the wire.
    private let resolvePolicy: (@MainActor (DashboardQuery) async -> IntervalPolicy?)?
    /// Per-site visitors preview for the picker list. Failures degrade to
    /// the plain row; never fake data.
    private let sparkline: ((SiteRef, AccountID) async -> TimeSeries?)?
    /// Per-site query controls plus last active site, persisted locally.
    private let preferences: SitePreferences
    private let widgetDestination: WidgetSiteDestination?
    private let onWidgetDestinationHandled: () -> Void
    /// Replays the introduction from Settings. Defaults to hidden.
    private let onReplayIntro: (() -> Void)?
    /// App-lock model for the Security settings row. Nil hides the row
    /// (mock roots, tests, and widget-less surfaces).
    private let appLock: AppLockModel?
    @State private var generation: UInt64 = 0
    @State private var handledWidgetDestination: WidgetSiteDestination?
    @State private var applyingWidgetDestination: WidgetSiteDestination?
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
#endif

    public init(
        directory: any SiteDirectory,
        overviewLoader: @escaping ReportModel<Overview>.Loader,
        seriesLoader: @escaping ReportModel<TimeSeries>.Loader,
        breakdownLoader: @escaping BreakdownModel.Loader,
        suggestions: SuggestionProvider? = nil,
        segmentList: SegmentListProvider? = nil,
        realtimeLoader: @escaping RealtimeModel.CountLoader,
        onSignOut: (@MainActor (AccountRef) async throws -> Void)? = nil,
        onExport: ExportButton.Exporter? = nil,
        resolveBase: (@MainActor (DashboardQuery) async -> DashboardQuery)? = nil,
        applyLock: (@MainActor (QueryModel) async -> Void)? = nil,
        resolvePolicy: (@MainActor (DashboardQuery) async -> IntervalPolicy?)? = nil,
        sparkline: ((SiteRef, AccountID) async -> TimeSeries?)? = nil,
        preferences: SitePreferences = SitePreferences(),
        widgetDestination: WidgetSiteDestination? = nil,
        onWidgetDestinationHandled: @escaping () -> Void = {},
        onReplayIntro: (() -> Void)? = nil,
        appLock: AppLockModel? = nil
    ) {
        _selection = State(initialValue: SiteSelectionModel(directory: directory))
        self.directory = directory
        self.overviewLoader = overviewLoader
        self.seriesLoader = seriesLoader
        self.breakdownLoader = breakdownLoader
        self.suggestions = suggestions
        self.segmentList = segmentList
        self.realtimeLoader = realtimeLoader
        self.onSignOut = onSignOut
        self.onExport = onExport
        self.resolveBase = resolveBase
        self.applyLock = applyLock
        self.resolvePolicy = resolvePolicy
        self.sparkline = sparkline
        self.preferences = preferences
        self.widgetDestination = widgetDestination
        self.onWidgetDestinationHandled = onWidgetDestinationHandled
        self.onReplayIntro = onReplayIntro
        self.appLock = appLock
    }

    public var body: some View {
        Group {
#if os(iOS)
            if sizeClass == .regular {
                splitView
            } else {
                tabView
            }
#else
            tabView
#endif
        }
        .onChange(of: selection.query) { _, query in
            rebuildModels(for: query)
        }
        .onChange(of: queryModel?.effective) {
            saveControls()
            updateRealtimeTick()
        }
        .onChange(of: selectedTab) { _, _ in
            updateRealtimeTick()
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reloadTodayIfNeeded() }
            }
        }
        .task(id: queryModel?.effective) {
            await refreshTodayAtSiteMidnight(queryModel?.effective)
        }
        .task {
            if let widgetDestination {
                selection.prepareWidgetDestination(domain: widgetDestination.domain)
            }
            await selection.loadAccounts()
            await applyWidgetDestination()
        }
        .onChange(of: widgetDestination) { _, destination in
            guard let destination else {
                handledWidgetDestination = nil
                return
            }
            selection.prepareWidgetDestination(domain: destination.domain)
            Task { await applyWidgetDestination() }
        }
        .onChange(of: selection.booted) { _, booted in
            guard booted else { return }
            Task { await applyWidgetDestination() }
        }
        .focusedValue(
            \.plauselyRefresh,
            PlauselyRefreshAction(refresh: {
                [overviewModel, channelsModel, sourcesModel, pagesModel, entryModel,
                 exitModel, countriesModel, browsersModel, screensModel, systemsModel,
                 goalsModel] in
                await overviewModel?.refresh(today: Date())
                let models = [channelsModel, sourcesModel, pagesModel, entryModel, exitModel,
                              countriesModel, browsersModel, screensModel, systemsModel].compactMap { $0 }
                await withTaskGroup(of: Void.self) { group in
                    for model in models {
                        group.addTask { await model.load(today: Date()) }
                    }
                }
                await goalsModel?.load(today: Date())
            })
        )
    }

    /// Compact iPhone layout: the native tab bar.
    private var tabView: some View {
        TabView(selection: $selectedTab) {
            HomeOverviewTab(
                selection: selection, queryModel: queryModel,
                overviewModel: overviewModel, realtimeModel: realtimeModel,
                sparkline: sparkline
            )
            .tabItem { Label("Overview", systemImage: "chart.line.uptrend.xyaxis").symbolEffect(.bounce, value: selectedTab) }
            .tag(Tab.overview)
            HomeBreakdownsTab(
                queryModel: queryModel,
                channelsModel: channelsModel, sourcesModel: sourcesModel,
                pagesModel: pagesModel, entryModel: entryModel,
                exitModel: exitModel, countriesModel: countriesModel,
                browsersModel: browsersModel, screensModel: screensModel,
                systemsModel: systemsModel,
                childFactory: childFactory,
                onFilter: filterAction,
                onExport: onExport,
                isActive: selectedTab == .breakdowns
            )
            .tabItem { Label("Breakdowns", systemImage: "list.bullet.rectangle").symbolEffect(.bounce, value: selectedTab) }
            .tag(Tab.breakdowns)
            HomeGoalsTab(
                queryModel: queryModel, goalsModel: goalsModel,
                childFactory: childFactory, onFilter: filterAction,
                isActive: selectedTab == .goals
            )
            .tabItem { Label("Goals", systemImage: "target").symbolEffect(.bounce, value: selectedTab) }
            .tag(Tab.goals)
            HomeSettingsTab(selection: selection, onSignOut: onSignOut, appLock: appLock, onReplayIntro: onReplayIntro)
                .tabItem { Label("Settings", systemImage: "gearshape.fill").symbolEffect(.bounce, value: selectedTab) }
                .tag(Tab.settings)
        }
    }

#if os(iOS)
    /// Regular-width iPad layout: sidebar navigation with the same tab
    /// content in detail. Compact iPhones keep the tab bar untouched.
    private var splitView: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(selectedTab) },
                set: { if let tab = $0 { selectedTab = tab } }
            )) {
                Label("Overview", systemImage: "chart.line.uptrend.xyaxis").tag(Tab.overview)
                    .symbolEffect(.bounce, value: selectedTab)
                Label("Breakdowns", systemImage: "list.bullet.rectangle").tag(Tab.breakdowns)
                    .symbolEffect(.bounce, value: selectedTab)
                Label("Goals", systemImage: "target").tag(Tab.goals)
                    .symbolEffect(.bounce, value: selectedTab)
                Label("Settings", systemImage: "gearshape.fill").tag(Tab.settings)
                    .symbolEffect(.bounce, value: selectedTab)
            }
            .navigationTitle("Plausely")
        } detail: {
            Group {
                switch selectedTab {
                case .overview:
                    HomeOverviewTab(
                        selection: selection, queryModel: queryModel,
                        overviewModel: overviewModel, realtimeModel: realtimeModel,
                        sparkline: sparkline
                    )
                case .breakdowns:
                    HomeBreakdownsTab(
                        queryModel: queryModel,
                        channelsModel: channelsModel, sourcesModel: sourcesModel,
                        pagesModel: pagesModel, entryModel: entryModel,
                        exitModel: exitModel, countriesModel: countriesModel,
                        browsersModel: browsersModel, screensModel: screensModel,
                        systemsModel: systemsModel,
                        childFactory: childFactory,
                        onFilter: filterAction,
                        onExport: onExport,
                        isActive: selectedTab == .breakdowns
                    )
                case .goals:
                    HomeGoalsTab(
                        queryModel: queryModel, goalsModel: goalsModel,
                        childFactory: childFactory, onFilter: filterAction,
                        isActive: selectedTab == .goals
                    )
                case .settings:
                    HomeSettingsTab(selection: selection, onSignOut: onSignOut, appLock: appLock, onReplayIntro: onReplayIntro)
                }
            }
        }
    }
#endif

    @MainActor
    private func applyWidgetDestination() async {
        guard let destination = widgetDestination,
              handledWidgetDestination != destination,
              applyingWidgetDestination != destination
        else { return }
        selection.prepareWidgetDestination(domain: destination.domain)
        guard selection.booted else { return }
        applyingWidgetDestination = destination
        let opened = await selection.openSite(accountID: destination.accountID, domain: destination.domain)
        applyingWidgetDestination = nil
        guard opened else { return }
        handledWidgetDestination = destination
        selectedTab = .overview
        onWidgetDestinationHandled()
    }

    // MARK: - Wiring (mirrors the legacy roots; only loaders differ)

    private func reloadTodayIfNeeded() async {
        guard let query = queryModel?.effective,
              query.period == .day,
              query.periodDate == nil else { return }
        // A cache-first reload can return yesterday's same-day entry when
        // the local query timezone has not caught up with the site's day.
        // Today must always revalidate against the server on foregrounding.
        await overviewModel?.refresh(today: Date())
    }

    private func refreshTodayAtSiteMidnight(_ query: DashboardQuery?) async {
        guard let query, query.period == .day, query.periodDate == nil else { return }
        while !Task.isCancelled {
            let now = Date()
            let nextRefresh = [query.timeZone, .current]
                .compactMap { timeZone -> Date? in
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = timeZone
                    return calendar.nextDate(
                        after: now,
                        matching: DateComponents(hour: 0, minute: 5),
                        matchingPolicy: .nextTime
                    )
                }
                .min()
            guard let nextRefresh else { return }
            do {
                try await Task.sleep(for: .seconds(nextRefresh.timeIntervalSince(now)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // Force the Today reports past the local cache at the day boundary.
            await overviewModel?.refresh(today: Date())
        }
    }

    /// Persists the working controls per site so revisits restore them.
    private func saveControls() {
        guard let queryModel, let effective = queryModel.effective else { return }
        preferences.saveControls(
            StoredControls(model: queryModel),
            account: effective.accountID,
            domain: effective.siteID.domain
        )
    }

    private var childFactory: BreakdownChildFactory? {
        let loader = breakdownLoader
        return { target, query in
            BreakdownModel(
                definition: breakdownDefinition(for: target.kind, title: target.title),
                query: breakdownQuery(query, adding: target.filter),
                loader: loader
            )
        }
    }

    private var filterAction: BreakdownFilterAction? {
        { [queryModel] clause in queryModel?.addClause(clause) ?? false }
    }

    private func rebuildModels(for query: DashboardQuery?) {
        // Clear synchronously so stale reports never linger, then build
        // exactly once: base resolution and lock application suspend, so a
        // generation guard drops overtaken windows.
        generation &+= 1
        let current = generation
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
        guard let query else { return }
        Task {
            let base = await resolveBase?(query) ?? query
            let policy = await resolvePolicy?(base)
            let queryModel = QueryModel(base: base, suggestions: suggestions, segmentList: segmentList, intervalPolicy: policy)
            await applyLock?(queryModel)
            if let stored = preferences.controls(account: base.accountID, domain: base.siteID.domain) {
                queryModel.applyStored(stored)
            }
            guard current == generation else { return }
            let effective = queryModel.effective ?? base
            self.queryModel = queryModel
            overviewModel = OverviewModel(
                overviewLoader: overviewLoader,
                seriesLoader: seriesLoader,
                overviewCache: overviewOverviewCache,
                seriesCache: overviewSeriesCache
            )
            let make = { (definition: ReportDefinition) in
                BreakdownModel(definition: definition, query: effective, loader: breakdownLoader)
            }
            channelsModel = make(.channels)
            sourcesModel = make(.sources)
            pagesModel = make(.pages)
            entryModel = make(.entryPages)
            exitModel = make(.exitPages)
            countriesModel = make(.countries)
            browsersModel = make(.browsers)
            screensModel = make(.screenSizes)
            systemsModel = make(.operatingSystems)
            goalsModel = make(.conversions)
            let realtimeLoader = realtimeLoader
            realtimeModel.start(account: effective.accountID, site: effective.siteID, loader: realtimeLoader)
            updateRealtimeTick()
        }
    }

    private func updateRealtimeTick() {        guard let effective = queryModel?.effective, effective.period == .realtime else {
            realtimeModel.onTick = nil
            return
        }
        realtimeModel.onTick = { [queryModel, overviewModel, channelsModel, sourcesModel, pagesModel, entryModel, exitModel, countriesModel, browsersModel, screensModel, systemsModel, goalsModel, selectedTab] in
            guard let current = queryModel?.effective else { return }
            switch selectedTab {
            case .overview:
                await overviewModel?.reload(query: current)
            case .breakdowns:
                let models = [channelsModel, sourcesModel, pagesModel, entryModel, exitModel,
                              countriesModel, browsersModel, screensModel, systemsModel].compactMap { $0 }
                await withTaskGroup(of: Void.self) { group in
                    for model in models {
                        group.addTask { await model.load() }
                    }
                }
            case .goals:
                await goalsModel?.load()
            case .settings:
                break
            }
        }
    }
}

