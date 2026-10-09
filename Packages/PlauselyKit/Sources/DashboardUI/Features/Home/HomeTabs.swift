import AnalyticsCore
import SwiftUI

/// Overview tab: pills, live hero, metric cards, chart, options, filters.
struct HomeOverviewTab: View {
    @Bindable var selection: SiteSelectionModel
    var queryModel: QueryModel?
    var overviewModel: OverviewModel?
    var realtimeModel: RealtimeModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HomeHeaderPills(selection: selection, queryModel: queryModel)
                if let queryModel {
                    HomeHeroView(model: realtimeModel)
                    // Reports need a runnable effective query; controls
                    // stay mounted on rejected combos so the typed error
                    // (e.g. realtime comparisons) remains visible and
                    // recoverable instead of unmounting with the reports.
                    if let overviewModel, let effective = queryModel.effective {
                        ReportStateView(
                            state: overviewModel.dashboard.overview.state,
                            onRetry: { Task { await overviewModel.refresh() } },
                            content: { HomeMetricCards(overview: $0.value) }
                        )
                        MetricPickerView(model: overviewModel)
                        HomeCard {
                            ReportStateView(
                                state: overviewModel.dashboard.series.state,
                                onRetry: { Task { await overviewModel.refresh() } },
                                content: {
                                    SeriesChartView(series: $0.value, metric: overviewModel.selectedMetric, period: effective.period, timeZone: effective.timeZone)
                                }
                            )
                        }
                        Spacer(minLength: 90)
                            .task(id: effective) {
                                await overviewModel.reload(query: effective)
                            }
                    }
                    HomeOptionsView(model: queryModel)
                    HomeCard {
                        FilterEditorView(model: queryModel)
                    }
                    Spacer(minLength: 90)
                } else {
                    // No site yet: the full picker beats an empty card.
                    SitePickerView(selection: selection)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .accessibilityIdentifier("home-pane-overview")
    }
}

/// Breakdowns tab: one family card per section plus the hub entries.
struct HomeBreakdownsTab: View {
    var queryModel: QueryModel?
    var channelsModel: BreakdownModel?
    var sourcesModel: BreakdownModel?
    var pagesModel: BreakdownModel?
    var entryModel: BreakdownModel?
    var exitModel: BreakdownModel?
    var countriesModel: BreakdownModel?
    var browsersModel: BreakdownModel?
    var screensModel: BreakdownModel?
    var systemsModel: BreakdownModel?
    var childFactory: BreakdownChildFactory?
    var onFilter: BreakdownFilterAction?
    var onExport: ExportButton.Exporter?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                familyCard(title: "Top channels", model: channelsModel, kind: .channels)
                familyCard(title: "Top sources", model: sourcesModel, kind: .sources)
                familyCard(title: "Top pages", model: pagesModel, kind: .pages)
                familyCard(title: "Top entry pages", model: entryModel, kind: .entryPages)
                familyCard(title: "Top exit pages", model: exitModel, kind: .exitPages)
                familyCard(title: "Top countries", model: countriesModel, kind: .countries)
                familyCard(title: "Browsers", model: browsersModel, kind: .browsers)
                familyCard(title: "Devices", model: screensModel, kind: .screenSizes)
                familyCard(title: "Operating systems", model: systemsModel, kind: .operatingSystems)
                if childFactory != nil, let effective = queryModel?.effective {
                    HomeCard {
                        VStack(spacing: 12) {
                            BreakdownHubButton(query: effective, childFactory: childFactory, onFilter: onFilter)
                            PropsHubButton(query: effective, childFactory: childFactory, onFilter: onFilter)
                        }
                    }
                }
                if onExport != nil, let effective = queryModel?.effective {
                    HomeCard {
                        ExportButton(query: effective, export: onExport)
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .accessibilityIdentifier("home-pane-breakdowns")
    }

    @ViewBuilder
    private func familyCard(title: String, model: BreakdownModel?, kind: ReportKind) -> some View {
        // No identifier on the card itself: a parent-applied id would
        // stamp over every descendant group id (summary rows, show-all),
        // repeating the ReportStateView report-value shadowing. Family
        // scoping already lives in the inner ids.
        if let model {
            HomeCard {
                VStack(alignment: .leading, spacing: 8) {
                    HomeCardTitle(title: title)
                    BreakdownSummaryView(
                        model: model,
                        query: queryModel?.effective,
                        childFactory: childFactory,
                        onFilter: onFilter
                    )
                }
            }
        }
    }
}

/// Goals tab: conversion table plus the property explorer.
struct HomeGoalsTab: View {
    var queryModel: QueryModel?
    var goalsModel: BreakdownModel?
    var childFactory: BreakdownChildFactory?
    var onFilter: BreakdownFilterAction?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let goalsModel {
                    // No card-level identifier here either (see familyCard):
                    // the conversions summary keeps its own row ids.
                    HomeCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HomeCardTitle(title: "Goal conversions")
                            BreakdownSummaryView(
                                model: goalsModel,
                                query: queryModel?.effective,
                                childFactory: childFactory,
                                onFilter: onFilter
                            )
                        }
                    }
                }
                if childFactory != nil, let effective = queryModel?.effective {
                    HomeCard {
                        PropsHubButton(query: effective, childFactory: childFactory, onFilter: onFilter)
                    }
                }
                if goalsModel == nil {
                    HomeCard {
                        Text("Select a site to inspect it.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .accessibilityIdentifier("home-pane-goals")
    }
}

/// Settings tab: instances plus client facts.
struct HomeSettingsTab: View {
    @Bindable var selection: SiteSelectionModel
    var onSignOut: (@MainActor (AccountRef) async throws -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HomeCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HomeCardTitle(title: "Instances")
                        if selection.accounts.isEmpty {
                            Text("No instances configured.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings-no-instances")
                        } else {
                            ForEach(selection.accounts, id: \.id) { account in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(account.displayName)
                                        Text(account.baseURL.absoluteString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if onSignOut != nil {
                                        Button("Sign Out") {
                                            Task { try? await onSignOut?(account) }
                                        }
                                        .accessibilityIdentifier("home-signout")
                                    }
                                }
                                .accessibilityIdentifier("settings-account-\(account.displayName)")
                            }
                        }
                    }
                }
                HomeCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HomeCardTitle(title: "About")
                        LabeledContent("Client", value: "Plausely")
                        LabeledContent("Dashboard target", value: "CE 3.2.1")
                    }
                }
                .accessibilityIdentifier("settings-content")
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .accessibilityIdentifier("home-pane-settings")
        .task {
            await selection.loadAccounts()
        }
    }
}
