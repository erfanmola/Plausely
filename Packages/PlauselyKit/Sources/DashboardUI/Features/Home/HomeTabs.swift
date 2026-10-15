import AnalyticsCore
import SwiftUI

/// Overview tab: pills, live hero, metric cards, chart, options, filters.
struct HomeOverviewTab: View {
    @Bindable var selection: SiteSelectionModel
    var queryModel: QueryModel?
    var overviewModel: OverviewModel?
    var realtimeModel: RealtimeModel
    var sparkline: ((SiteRef, AccountID) async -> TimeSeries?)?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HomeHeaderPills(selection: selection, queryModel: queryModel)
                if !selection.booted {
                    if let domain = selection.pendingSiteDomain {
                        siteLoadingView(domain)
                    } else {
                        // First paint: picker-shaped shimmer for the
                        // directory + restore, never a premature picker.
                        BootSkeleton()
                            .accessibilityIdentifier("home-boot")
                            .padding(.top, 8)
                    }
                } else if let queryModel {
                    HomeHeroView(model: realtimeModel)
                    // Reports need a runnable effective query; controls
                    // stay mounted on rejected combos so the typed error
                    // (e.g. realtime comparisons) remains visible and
                    // recoverable instead of unmounting with the reports.
                    if let overviewModel, let effective = queryModel.effective {
                        ReportStateView(
                            state: overviewModel.dashboard.overview.state,
                            onRetry: { Task { await overviewModel.refresh() } },
                            skeleton: { MetricCardsSkeleton() },
                            content: { HomeMetricCards(overview: $0.value, trend: overviewModel.dashboard.trend.state.displayable?.value) }
                        )
                        MetricPickerView(model: overviewModel)
                        HomeCard {
                            ReportStateView(
                                state: overviewModel.dashboard.series.state,
                                onRetry: { Task { await overviewModel.refresh() } },
                                skeleton: { ChartSkeleton(reserveCaption: effective.period == .day && effective.periodDate == nil) },
                                content: {
                                    SeriesChartView(series: $0.value, metric: overviewModel.selectedMetric, period: effective.period, periodDate: effective.periodDate, timeZone: effective.timeZone)
                                }
                            )
                        }
                        Spacer(minLength: 90)
                        .task(id: effective) {
                            let isToday = effective.period == .day && effective.periodDate == nil
                            await overviewModel.reload(query: effective, revalidate: isToday)
                        }
                    }
                    HomeOptionsView(model: queryModel)
                    HomeCard {
                        FilterEditorView(model: queryModel)
                    }
                    Spacer(minLength: 90)
                } else if let site = selection.selectedSite {
                    siteLoadingView(site.domain)
                } else if let domain = selection.pendingSiteDomain {
                    siteLoadingView(domain)
                } else {
                    // No site yet: the full picker beats an empty card.
                    SitePickerView(selection: selection, sparkline: sparkline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .refreshable {
            if let overviewModel {
                await overviewModel.refresh(today: Date())
            } else {
                await selection.retrySites()
            }
        }
        .accessibilityIdentifier("home-pane-overview")
    }

    private func siteLoadingView(_ domain: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading \(domain)…")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityIdentifier("site-dashboard-loading")
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
    var isActive = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if queryModel == nil {
                    HomeCard {
                        ContentUnavailableView(
                            "No site selected",
                            systemImage: "chart.bar.doc.horizontal",
                            description: Text("Choose a site to see channels, sources, pages, geography, and devices.")
                        )
                        .accessibilityIdentifier("home-breakdowns-empty")
                    }
                }
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
        .refreshable {
            let models = [channelsModel, sourcesModel, pagesModel, entryModel, exitModel,
                          countriesModel, browsersModel, screensModel, systemsModel].compactMap { $0 }
            await withTaskGroup(of: Void.self) { group in
                for model in models {
                    group.addTask { await model.load(today: Date()) }
                }
            }
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
                        onFilter: onFilter,
                        isActive: isActive
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
    var isActive = true

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
                                onFilter: onFilter,
                                isActive: isActive
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
                        ContentUnavailableView(
                            "No site selected",
                            systemImage: "target",
                            description: Text("Choose a site to inspect goal conversions and properties.")
                        )
                        .accessibilityIdentifier("home-goals-empty")
                    }
                }
                Spacer(minLength: 90)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .refreshable {
            await goalsModel?.load(today: Date())
        }
        .accessibilityIdentifier("home-pane-goals")
    }
}

/// Telegram-style settings row: colorful rounded-square glyph, title,
/// trailing gray value, chevron. Used for navigable settings entries.
struct SettingsRow<Destination: View>: View {
    private let icon: String
    private let tint: Color
    private let title: String
    private let value: String?
    private let identifier: String
    private let destination: () -> Destination

    init(
        icon: String,
        tint: Color,
        title: String,
        value: String? = nil,
        identifier: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.value = value
        self.identifier = identifier
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// Settings tab: instances plus client facts.
struct HomeSettingsTab: View {
    @Bindable var selection: SiteSelectionModel
    var onSignOut: (@MainActor (AccountRef) async throws -> Void)?
    var appLock: AppLockModel?
    var onReplayIntro: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HomeCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HomeCardTitle(title: "Instances")
                            if selection.accounts.isEmpty {
                                ContentUnavailableView(
                                    "No instances configured",
                                    systemImage: "server.rack",
                                    description: Text("Sign in to an analytics instance to browse its sites.")
                                )
                                .accessibilityIdentifier("settings-no-instances")
                            } else {
                                ForEach(selection.accounts, id: \.id) { account in
                                    HStack(spacing: 12) {
                                        SiteMonogram(domain: account.displayName)
                                        VStack(alignment: .leading) {
                                            Text(account.displayName)
                                            Text(account.baseURL.absoluteString)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        if onSignOut != nil {
                                            Button("Sign Out", role: .destructive) {
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
                    if let appLock {
                        HomeCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HomeCardTitle(title: "Security")
                                SettingsRow(
                                    icon: "lock.fill",
                                    tint: .green,
                                    title: "Passcode & Face ID",
                                    value: appLock.isEnabled ? "On" : "Off",
                                    identifier: "settings-applock",
                                    destination: { AppLockSettingsView(model: appLock) }
                                )
                            }
                        }
                    }
                    HomeCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HomeCardTitle(title: "Appearance")
                            SettingsRow(
                                icon: "paintpalette.fill",
                                tint: .blue,
                                title: "Theme & accent",
                                value: AppAppearance.shared.theme.title,
                                identifier: "settings-appearance",
                                destination: { AppAppearanceView() }
                            )
                        }
                    }
                    HomeCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HomeCardTitle(title: "About")
                            LabeledContent("Client", value: "Plausely")
                            LabeledContent("Dashboard target", value: "CE 3.2.1")
                            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                            {
                                LabeledContent("Version", value: "\(version) (\(build))")
                            }
                            if onReplayIntro != nil {
                                Button("Show introduction") { onReplayIntro?() }
                                    .accessibilityIdentifier("settings-replay-intro")
                            }
                        }
                    }
                    .accessibilityIdentifier("settings-content")
                    Spacer(minLength: 90)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("Settings")
            .refreshable {
                await selection.loadAccounts()
            }
        }
        .accessibilityIdentifier("home-pane-settings")
        .task {
            await selection.loadAccounts()
        }
    }
}
