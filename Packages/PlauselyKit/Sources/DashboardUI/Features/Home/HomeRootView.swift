import AnalyticsCore
import SwiftUI

/// Home root: pill header, four tabs, floating pill bar. Owns the
/// window's selection and every report model; loaders arrive injected so
/// mock and live share every pixel on both platforms.
public struct HomeRootView: View {
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
    @State private var generation: UInt64 = 0

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
        applyLock: (@MainActor (QueryModel) async -> Void)? = nil
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
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .overview:
                    HomeOverviewTab(
                        selection: selection, queryModel: queryModel,
                        overviewModel: overviewModel, realtimeModel: realtimeModel
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
                        onExport: onExport
                    )
                case .goals:
                    HomeGoalsTab(
                        queryModel: queryModel, goalsModel: goalsModel,
                        childFactory: childFactory, onFilter: filterAction
                    )
                case .settings:
                    HomeSettingsTab(selection: selection, onSignOut: onSignOut)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PillTabBar(selected: $selectedTab)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .background(HomeStyle.page.ignoresSafeArea())
        .onChange(of: selection.query) { _, query in
            rebuildModels(for: query)
        }
        .onChange(of: queryModel?.effective) {
            updateRealtimeTick()
        }
        .task {
            await selection.loadAccounts()
        }
    }

    // MARK: - Wiring (mirrors the legacy roots; only loaders differ)

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
            let queryModel = QueryModel(base: base, suggestions: suggestions, segmentList: segmentList)
            await applyLock?(queryModel)
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
}

/// Floating pill tab bar: four destinations, selected pill glides with a
/// matched geometry effect and ticks haptically.
struct PillTabBar: View {
    @Binding var selected: HomeRootView.Tab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HomeRootView.Tab.allCases, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: symbol(for: tab))
                            .font(.title3)
                        Text(title(for: tab))
                            .font(.caption2)
                    }
                    .foregroundStyle(selected == tab ? .indigo : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background {
                        if selected == tab {
                            Capsule(style: .continuous)
                                .fill(Color.indigo.opacity(0.12))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                }
                .accessibilityIdentifier("home-tab-\(tab.rawValue)")
            }
        }
        .padding(8)
        .background(HomeStyle.card, in: Capsule(style: .continuous))
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func symbol(for tab: HomeRootView.Tab) -> String {
        switch tab {
        case .overview: return "chart.line.uptrend.xyaxis"
        case .breakdowns: return "list.bullet.rectangle"
        case .goals: return "target"
        case .settings: return "gearshape.fill"
        }
    }

    private func title(for tab: HomeRootView.Tab) -> String {
        switch tab {
        case .overview: return "Overview"
        case .breakdowns: return "Breakdowns"
        case .goals: return "Goals"
        case .settings: return "Settings"
        }
    }
}
