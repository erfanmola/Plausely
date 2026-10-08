import AnalyticsCore
import DashboardUI
import SwiftUI

@main
struct PlauselyApp: App {
    /// Deterministic mock launch for UI smoke tests. Real dependency
    /// injection lands with feature work; this flag only swaps the root.
    static var isMockLaunch: Bool {
        CommandLine.arguments.contains("-plausely-mock")
    }

    static var isMockSites: Bool {
        CommandLine.arguments.contains("-plausely-mock-sites")
    }

    static var directory: any SiteDirectory {
        isMockSites ? MockSiteDirectory.thirteenSites() : EmptySiteDirectory()
    }

    var body: some Scene {
        WindowGroup {
            if Self.isMockLaunch {
                Text("Mock")
            } else if Self.isMockSites {
                IOSRootView(directory: Self.directory, mockProviders: true)
            } else {
                LiveRootView()
            }
        }
    }
}

/// Per-window root: each window owns its selection model, so site/query
/// state never crosses windows.
struct IOSRootView: View {
    @State private var selection: SiteSelectionModel
    @State private var queryModel: QueryModel?
    @State private var overviewModel: OverviewModel?
    @State private var sourcesModel: BreakdownModel?
    @State private var channelsModel: BreakdownModel?
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
    private let mockProviders: Bool

    init(directory: any SiteDirectory, mockProviders: Bool = false) {
        _selection = State(initialValue: SiteSelectionModel(directory: directory))
        self.mockProviders = mockProviders
    }

    /// Drilldown factory: resolves the target kind to its definition and
    /// merges any hierarchy filter into a copy of the current query.
    /// Mock loaders only; the real service arrives with client wiring.
    static func breakdownChild(mockProviders: Bool) -> BreakdownChildFactory? {
        guard mockProviders else { return nil }
        return { target, query in
            BreakdownModel(
                definition: breakdownDefinition(for: target.kind, title: target.title),
                query: breakdownQuery(query, adding: target.filter),
                loader: MockBreakdownProviders.loader
            )
        }
    }

    var body: some View {
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
                breakdownChild: IOSRootView.breakdownChild(mockProviders: mockProviders),
                onBreakdownFilter: { [queryModel] clause in queryModel?.addClause(clause) ?? false },
                realtimeModel: realtimeModel,
                onExport: mockProviders ? { _ in (filename: "mock-export.zip", data: MockExportProviders.payload) } : nil
            )
        }
        .onChange(of: selection.query) { _, query in
            rebuildModels(for: query)
        }
        .onChange(of: queryModel?.effective) {
            updateRealtimeTick()
        }
    }

    /// Rebuilds every report model for the selected query and (re)starts
    /// the live headcount. Models after this point mirror the live root's
    /// construction; only the loaders differ.
    private func rebuildModels(for query: DashboardQuery?) {
        queryModel = query.map {
            QueryModel(
                base: $0,
                suggestions: mockProviders ? MockQueryProviders.suggestions : nil,
                segmentList: mockProviders ? MockQueryProviders.segments : nil
            )
        }
        // Overview loaders come from the real service with the
        // client-wiring follow-on; mock fixtures only in mock mode.
        overviewModel = mockProviders
            ? OverviewModel(
                overviewLoader: MockOverviewProviders.overview,
                seriesLoader: MockOverviewProviders.series,
                overviewCache: overviewOverviewCache,
                seriesCache: overviewSeriesCache
            ) : nil
        // Breakdown families (05.2 acquisition, 05.4 pages, 06 geo/devices);
        // mock loaders only in mock mode, real service with client wiring.
        sourcesModel = breakdownModel(query: query, definition: .sources)
        channelsModel = breakdownModel(query: query, definition: .channels)
        pagesModel = breakdownModel(query: query, definition: .pages)
        entryModel = breakdownModel(query: query, definition: .entryPages)
        exitModel = breakdownModel(query: query, definition: .exitPages)
        countriesModel = breakdownModel(query: query, definition: .countries)
        browsersModel = breakdownModel(query: query, definition: .browsers)
        screensModel = breakdownModel(query: query, definition: .screenSizes)
        systemsModel = breakdownModel(query: query, definition: .operatingSystems)
        goalsModel = breakdownModel(query: query, definition: .conversions)
        if let query, mockProviders {
            realtimeModel.start(account: query.accountID, site: query.siteID, loader: MockRealtimeProviders.count)
        } else {
            realtimeModel.stop()
        }
        updateRealtimeTick()
    }

    private func breakdownModel(query: DashboardQuery?, definition: ReportDefinition) -> BreakdownModel? {
        query.flatMap {
            mockProviders
                ? BreakdownModel(definition: definition, query: $0, loader: MockBreakdownProviders.loader)
                : nil
        }
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
}
