import Charts
import SwiftUI

/// Watch views: site picker, realtime + overview with charts, and a
/// read-only breakdowns tab. All data is proxied through the iPhone
/// (`WatchSessionManager`); the watch holds no secrets and makes no API
/// calls. Mock mode (`-plausely-mock`) renders `WatchMock` payloads with no
/// phone, for simulator screenshots and previews.
struct WatchRootView: View {
    @Bindable var link: WatchSessionManager
    @State private var path: [WatchSite] = []

    var body: some View {
        NavigationStack(path: $path) {
            WatchSiteListView(link: link) { site in
                path.append(site)
            }
            .navigationDestination(for: WatchSite.self) { site in
                WatchSiteDetailView(link: link, site: site)
            }
        }
    }
}

struct WatchSiteListView: View {
    @Bindable var link: WatchSessionManager
    var onSelect: (WatchSite) -> Void

    var body: some View {
        List {
            if link.sitesLoading, link.sites.isEmpty {
                ProgressView("Loading sites…")
            } else if let error = link.sitesError, link.sites.isEmpty {
                ContentUnavailableView {
                    Label("No connection", systemImage: "applewatch.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await link.refreshSites() } }
                }
            } else if link.sites.isEmpty {
                ContentUnavailableView {
                    Label("No sites", systemImage: "globe")
                } description: {
                    Text("Open Plausely on iPhone and sign in to see your sites.")
                } actions: {
                    Button("Retry") { Task { await link.refreshSites() } }
                }
            } else {
                ForEach(link.sites) { site in
                    Button {
                        onSelect(site)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.domain)
                                .font(.headline)
                                .lineLimit(1)
                            Text(site.accountName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("watch-site-\(site.domain)")
                }
            }
        }
        .navigationTitle("Sites")
        .task {
            await link.refreshSites()
            // Screenshot deep-link: `-plausely-watch-site <domain>` opens
            // the detail directly, so simulator captures don't need taps
            // (simctl cannot synthesize them).
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "-plausely-watch-site"), i + 1 < args.count {
                let domain = args[i + 1]
                if let site = link.sites.first(where: { $0.domain == domain }) {
                    onSelect(site)
                }
            }
        }
        .refreshable { await link.refreshSites() }
    }
}

struct WatchSiteDetailView: View {
    @Bindable var link: WatchSessionManager
    let site: WatchSite
    @State private var period: WatchPeriod = .last28Days
    @State private var response: WatchOverviewResponse?
    @State private var loading = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                periodPicker
                realtimeSection
                if loading, response == nil {
                    ProgressView("Loading…")
                } else if let response {
                    if let error = response.error, response.metrics.isEmpty {
                        ContentUnavailableView {
                            Label("Couldn't load", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        }
                    } else {
                        chartSection(response)
                            .id("chart")
                        metricsSection(response)
                        breakdownLink
                    }
                }
            }
            .navigationTitle(site.domain)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: period) { await load(proxy: proxy) }
            .refreshable { await load(proxy: nil) }
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(WatchPeriod.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .accessibilityIdentifier("watch-period")
    }

    @ViewBuilder
    private var realtimeSection: some View {
        if let count = response?.realtimeVisitors {
            Section("Realtime") {
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("\(count) current visitors")
                        .font(.headline)
                }
                .accessibilityIdentifier("watch-realtime")
            }
        }
    }

    private func chartSection(_ response: WatchOverviewResponse) -> some View {
        Section(response.periodTitle) {
            if response.chartValues.compactMap({ $0 }).isEmpty {
                Text("No chart data for this period.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(Array(response.chartValues.enumerated()), id: \.offset) { item in
                        if let value = item.element {
                            AreaMark(
                                x: .value("Bucket", item.offset),
                                y: .value("Visitors", value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.tint.opacity(0.14))
                            LineMark(
                                x: .value("Bucket", item.offset),
                                y: .value("Visitors", value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .accessibilityHidden(true)
            }
        }
    }

    private func metricsSection(_ response: WatchOverviewResponse) -> some View {
        Section("Metrics") {
            ForEach(Array(response.metrics.enumerated()), id: \.offset) { item in
                HStack {
                    Text(item.element.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(item.element.displayValue)
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                        if let change = item.element.changeText {
                            Text(change)
                                .font(.caption2)
                                .foregroundStyle(change.hasPrefix("-") ? .red : .green)
                        }
                    }
                }
                .accessibilityIdentifier("watch-metric-\(item.offset)")
            }
        }
    }

    private var breakdownLink: some View {
        Section("Breakdowns") {
            ForEach(WatchDimension.allCases, id: \.self) { dimension in
                NavigationLink(dimension.title) {
                    WatchBreakdownView(link: link, site: site, period: period, dimension: dimension)
                }
                .accessibilityIdentifier("watch-dimension-\(dimension.rawValue)")
            }
        }
    }

    private func load(proxy: ScrollViewProxy?) async {
        loading = true
        defer { loading = false }
        response = await link.overview(site: site, period: period)
        // Screenshot hook: `-plausely-watch-shot` frames the chart so
        // simulator captures (no taps via simctl) show graphs, not the
        // period picker fold. Mock/screenshot path only.
        if CommandLine.arguments.contains("-plausely-watch-shot"), response != nil, let proxy {
            // Beat for the list to lay out before scrolling.
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation { proxy.scrollTo("chart", anchor: .top) }
        }
    }
}

struct WatchBreakdownView: View {
    @Bindable var link: WatchSessionManager
    let site: WatchSite
    let period: WatchPeriod
    @State var dimension: WatchDimension
    @State private var response: WatchBreakdownResponse?
    @State private var loading = false

    var body: some View {
        List {
            Picker("Dimension", selection: $dimension) {
                ForEach(WatchDimension.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityIdentifier("watch-dimension-picker")
            if loading, response == nil {
                ProgressView("Loading…")
            } else if let response {
                if let error = response.error, response.rows.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if response.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No data", systemImage: "tray")
                    } description: {
                        Text("No \(dimension.title.lowercased()) for this period.")
                    }
                } else {
                    ForEach(Array(response.rows.enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.name)
                                .font(.caption)
                                .lineLimit(2)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(item.element.valueText)
                                    .font(.body.weight(.semibold))
                                    .monospacedDigit()
                                if let change = item.element.changeText {
                                    Text(change)
                                        .font(.caption2)
                                        .foregroundStyle(change.hasPrefix("-") ? .red : .green)
                                }
                            }
                        }
                        .accessibilityIdentifier("watch-row-\(item.offset)")
                    }
                }
            }
        }
        .navigationTitle(dimension.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dimension) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        response = await link.breakdown(site: site, period: period, dimension: dimension)
    }
}

#Preview {
    WatchSiteDetailView(
        link: {
            let manager = WatchSessionManager()
            manager.sites = WatchMock.sites
            return manager
        }(),
        site: WatchMock.sites[0]
    )
}
