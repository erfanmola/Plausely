import AnalyticsCore
import SwiftUI

/// Sidebar: instance picker plus the team's site list. Selection drives the
/// window's query through the model; each window owns its model, so state
/// never crosses windows.
public struct SiteSidebarView: View {
    @Bindable private var model: SiteSelectionModel
    @State private var searchText = ""

    public init(model: SiteSelectionModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.accounts.isEmpty {
                Menu {
                    ForEach(model.accounts, id: \.id) { account in
                        Button(account.displayName) {
                            Task { await model.selectAccount(account.id) }
                        }
                    }
                } label: {
                    Label(model.selectedAccount?.displayName ?? "Instance", systemImage: "server.rack")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityIdentifier("account-picker")
                .padding(.horizontal)
                Divider()
            }
            Group {
                if model.accounts.isEmpty {
                    ContentUnavailableView(
                        "No instances",
                        systemImage: "server.rack",
                        description: Text("Add an instance in Settings to browse its sites.")
                    )
                    .accessibilityIdentifier("no-instances")
                } else if model.sitesLoading, model.sites.isEmpty {
                    ProgressView("Loading sites…")
                        .accessibilityIdentifier("sites-loading")
                } else if let error = model.sitesError, model.sites.isEmpty {
                    ContentUnavailableView(
                        "Couldn't load sites",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.message)
                    )
                    Button("Retry") { Task { await model.retrySites() } }
                        .accessibilityIdentifier("sites-retry")
                } else {
                    List(selection: siteSelection) {
                        ForEach(model.siteSections, id: \.name) { section in
                            Section(section.name) {
                                ForEach(visibleSites(in: section.sites), id: \.domain) { site in
                                    siteRow(site)
                                        .tag(site.domain)
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search sites")
                }
            }
        }
        .accessibilityIdentifier("site-sidebar")
        .task { await model.loadAccounts() }
    }

    private var siteSelection: Binding<String?> {
        Binding(
            get: { model.selectedDomain },
            set: { model.selectSite($0) }
        )
    }

    private func visibleSites(in sites: [SiteRef]) -> [SiteRef] {
        guard !searchText.isEmpty else { return sites }
        return sites.filter { $0.domain.localizedCaseInsensitiveContains(searchText) }
    }

    private func siteRow(_ site: SiteRef) -> some View {
        VStack(alignment: .leading) {
            Text(site.domain)
                .lineLimit(1)
                .truncationMode(.middle)
            if let role = site.role {
                Text(role.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("site-row-\(site.domain)")
    }
}

/// Detail for the selected site. Report views land in 04.4; until then this
/// shows only verified selection/query facts, never fabricated numbers.
/// Pass a query model to attach the 04.3 period/filter controls, an
/// overview model (with injected loaders) to attach the 04.4 overview, and
/// acquisition models plus report wiring for the 05.2 families.
public struct SiteDetailView: View {
    private let site: SiteRef?
    private let query: DashboardQuery?
    private let queryModel: QueryModel?
    private let overviewModel: OverviewModel?
    private let channelsModel: BreakdownModel?
    private let sourcesModel: BreakdownModel?
    private let pagesModel: BreakdownModel?
    private let entryModel: BreakdownModel?
    private let exitModel: BreakdownModel?
    private let countriesModel: BreakdownModel?
    private let browsersModel: BreakdownModel?
    private let screensModel: BreakdownModel?
    private let systemsModel: BreakdownModel?
    private let goalsModel: BreakdownModel?
    private let breakdownChild: BreakdownChildFactory?
    private let onBreakdownFilter: BreakdownFilterAction?
    private let realtimeModel: RealtimeModel?
    private let onExport: ExportButton.Exporter?

    public init(
        site: SiteRef?,
        query: DashboardQuery?,
        queryModel: QueryModel? = nil,
        overviewModel: OverviewModel? = nil,
        channelsModel: BreakdownModel? = nil,
        sourcesModel: BreakdownModel? = nil,
        pagesModel: BreakdownModel? = nil,
        entryModel: BreakdownModel? = nil,
        exitModel: BreakdownModel? = nil,
        countriesModel: BreakdownModel? = nil,
        browsersModel: BreakdownModel? = nil,
        screensModel: BreakdownModel? = nil,
        systemsModel: BreakdownModel? = nil,
        goalsModel: BreakdownModel? = nil,
        breakdownChild: BreakdownChildFactory? = nil,
        onBreakdownFilter: BreakdownFilterAction? = nil,
        realtimeModel: RealtimeModel? = nil,
        onExport: ExportButton.Exporter? = nil
    ) {
        self.site = site
        self.query = query
        self.queryModel = queryModel
        self.overviewModel = overviewModel
        self.channelsModel = channelsModel
        self.sourcesModel = sourcesModel
        self.pagesModel = pagesModel
        self.entryModel = entryModel
        self.exitModel = exitModel
        self.countriesModel = countriesModel
        self.browsersModel = browsersModel
        self.screensModel = screensModel
        self.systemsModel = systemsModel
        self.goalsModel = goalsModel
        self.breakdownChild = breakdownChild
        self.onBreakdownFilter = onBreakdownFilter
        self.realtimeModel = realtimeModel
        self.onExport = onExport
    }

    public var body: some View {
        Group {
            if let site {
                List {
                    Section("Site") {
                        LabeledContent("Domain", value: site.domain)
                        if let realtimeModel {
                            RealtimeBadge(model: realtimeModel)
                        }
                        if let team = site.teamName ?? site.teamID {
                            LabeledContent("Team", value: team)
                        }
                        if let role = site.role {
                            LabeledContent("Role", value: role.capitalized)
                        }
                    }
                    if let query {
                        Section("Query") {
                            LabeledContent("Period", value: query.period.wireValue)
                            LabeledContent("Metric", value: query.selectedMetric.rawValue)
                            LabeledContent("Timezone", value: query.timeZone.identifier)
                        }
                    }
                    if let queryModel {
                        Section("Period & comparison") {
                            QueryToolbarView(model: queryModel)
                        }
                        FilterEditorView(model: queryModel)
                    }
                    if let overviewModel, let effective = queryModel?.effective {
                        Section("Overview") {
                            OverviewContentView(query: effective, model: overviewModel)
                        }
                    }
                    if let goalsModel {
                        Section("Goals") {
                            BreakdownSummaryView(
                                model: goalsModel,
                                query: queryModel?.effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if let channelsModel {
                        Section("Top channels") {
                            BreakdownSummaryView(
                                model: channelsModel,
                                query: queryModel?.effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if let sourcesModel {
                        Section("Top sources") {
                            BreakdownSummaryView(
                                model: sourcesModel,
                                query: queryModel?.effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if breakdownChild != nil, let effective = queryModel?.effective {
                        Section("UTM reports") {
                            BreakdownHubButton(
                                query: effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                        Section("Properties") {
                            PropsHubButton(
                                query: effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if onExport != nil, let effective = queryModel?.effective {
                        Section("Export") {
                            ExportButton(query: effective, export: onExport)
                        }
                    }
                    if let pagesModel {
                        Section("Top pages") {
                            BreakdownSummaryView(
                                model: pagesModel,
                                query: queryModel?.effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if let entryModel {
                        Section("Top entry pages") {
                            BreakdownSummaryView(
                                model: entryModel,
                                query: queryModel?.effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if let exitModel {
                        Section("Top exit pages") {
                            BreakdownSummaryView(
                                model: exitModel,
                                query: queryModel?.effective,
                                childFactory: breakdownChild,
                                onFilter: onBreakdownFilter
                            )
                        }
                    }
                    if countriesModel != nil {
                        Section("Geography") {
                            if let countriesModel {
                                CountryDistributionView(model: countriesModel)
                                BreakdownSummaryView(
                                    model: countriesModel,
                                    query: queryModel?.effective,
                                    childFactory: breakdownChild,
                                    onFilter: onBreakdownFilter
                                )
                            }
                        }
                    }
                    if browsersModel != nil || screensModel != nil || systemsModel != nil {
                        Section("Devices") {
                            if let browsersModel {
                                BreakdownSummaryView(
                                    model: browsersModel,
                                    query: queryModel?.effective,
                                    childFactory: breakdownChild,
                                    onFilter: onBreakdownFilter
                                )
                            }
                            if let screensModel {
                                BreakdownSummaryView(
                                    model: screensModel,
                                    query: queryModel?.effective,
                                    childFactory: breakdownChild,
                                    onFilter: onBreakdownFilter
                                )
                            }
                            if let systemsModel {
                                BreakdownSummaryView(
                                    model: systemsModel,
                                    query: queryModel?.effective,
                                    childFactory: breakdownChild,
                                    onFilter: onBreakdownFilter
                                )
                            }
                        }
                    }
                }
                .navigationTitle(site.domain)
                .accessibilityIdentifier("site-detail")
            } else {
                ContentUnavailableView(
                    "Select a site",
                    systemImage: "chart.bar",
                    description: Text("Pick a site from the sidebar to inspect it.")
                )
                .accessibilityIdentifier("site-empty")
            }
        }
    }
}

/// Settings content shared by all platforms: instance accounts on this
/// device plus client facts. Secrets never appear here.
public struct SettingsContentView: View {
    @Bindable private var model: SiteSelectionModel

    public init(model: SiteSelectionModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Instances") {
                if model.accounts.isEmpty {
                    Text("No instances configured.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-no-instances")
                } else {
                    ForEach(model.accounts, id: \.id) { account in
                        VStack(alignment: .leading) {
                            Text(account.displayName)
                            Text(account.baseURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("settings-account-\(account.displayName)")
                    }
                }
            }
            Section("About") {
                LabeledContent("Client", value: "Plausely")
                LabeledContent("Dashboard target", value: "CE 3.2.1")
            }
        }
        .accessibilityIdentifier("settings-content")
        .task { await model.loadAccounts() }
    }
}
