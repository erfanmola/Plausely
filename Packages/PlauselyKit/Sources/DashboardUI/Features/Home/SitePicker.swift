import AnalyticsCore
import Charts
import SwiftUI

/// Domain monogram: frosted-glass squircle with the site initial, in the
/// iOS 26 clear-icon spirit (monochrome, depth from the material, not
/// from color). Offline and deterministic. Decorative; rows carry the
/// accessible names.
struct SiteMonogram: View {
    let domain: String

    var body: some View {
        Text(letter)
            .font(.headline)
            .bold()
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .glassTile(cornerRadius: 12)
            .accessibilityHidden(true)
    }

    private var letter: String {
        domain.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }
}

/// One picker row: monogram, domain, meta, pin toggle, and a lazily
/// loaded visitors sparkline. Failed previews degrade to the plain row —
/// never a fake chart, never a spinner farm.
struct SiteRowView: View {
    let site: SiteRef
    let account: AccountRef?
    let pinned: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    var sparkline: ((SiteRef, AccountID) async -> TimeSeries?)?
    @State private var preview: TimeSeries?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    HStack(spacing: 12) {
                        SiteMonogram(domain: site.domain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.domain)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            if let meta = siteMeta(site) {
                                Text(meta)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .bold()
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("site-option-\(site.domain)")
                Button(action: onTogglePin) {
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(pinned ? .yellow : .secondary)
                        .symbolEffect(.bounce, value: pinned)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("site-pin-\(site.domain)")
                .accessibilityLabel(pinned ? "Unpin \(site.domain)" : "Pin \(site.domain)")
            }
            if sparkline != nil {
                sparklineSlot
            }
        }
        .padding(.vertical, 4)
        .task {
            guard preview == nil, let account, let sparkline else { return }
            preview = await sparkline(site, account.id)
        }
    }

    @ViewBuilder
    private var sparklineSlot: some View {
        if let preview {
            MiniSparkline(series: preview)
                .frame(height: 30)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.secondary.opacity(0.1))
                .frame(height: 30)
                .accessibilityHidden(true)
        }
    }

    private func siteMeta(_ site: SiteRef) -> String? {
        switch (site.teamName ?? site.teamID, site.role) {
        case (nil, nil): return nil
        case (let team?, nil): return team
        case (nil, let role?): return role.capitalized
        case (let team?, let role?): return "\(team) · \(role.capitalized)"
        }
    }
}

/// 30pt visitors sparkline for picker rows. Gaps are bridged: this is a
/// shape preview, and the full chart stays the source of truth.
struct MiniSparkline: View {
    let series: TimeSeries

    var body: some View {
        let values: [Double] = SeriesPoints.build(from: series).compactMap(\.value)
        if !values.isEmpty {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("Bucket", index), y: .value("Visitors", value))
                        .interpolationMethod(.catmullRom)
                }
                .foregroundStyle(.secondary)
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Bucket", index), y: .value("Visitors", value))
                        .interpolationMethod(.catmullRom)
                }
                .foregroundStyle(Color.accentColor.opacity(0.25))
            }
            .chartXScale(range: .plotDimension(startPadding: 0, endPadding: 0))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .accessibilityHidden(true)
        }
    }
}

/// Elegant site picker for the unselected state (and anywhere a full
/// list beats a menu): pinned sites first, then team sections, monograms,
/// per-site preview graphs, inline filter for long lists. Selecting a
/// site builds its query; account switching stays in the header menu
/// and Settings.
struct SitePickerView: View {
    @Bindable var selection: SiteSelectionModel
    var sparkline: ((SiteRef, AccountID) async -> TimeSeries?)?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a site")
                    .font(.title2)
                    .bold()
                    .accessibilityIdentifier("site-picker-title")
                Text("Stats load for one site at a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selection.sites.count > 6 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter sites", text: $filter)
                        .accessibilityIdentifier("site-picker-filter")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if selection.sitesLoading, selection.sites.isEmpty {
                VStack(spacing: 2) {
                    ForEach(0 ..< 4, id: \.self) { _ in
                        SiteRowSkeleton()
                    }
                }
                .accessibilityIdentifier("site-picker-loading")
            } else if let failure = selection.sitesError, selection.sites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't load sites.", systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("site-picker-error")
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await selection.retrySites() }
                    }
                    .accessibilityIdentifier("site-picker-retry")
                }
            } else if visiblePinned.isEmpty, visibleSections.isEmpty {
                if selection.accounts.isEmpty {
                    ContentUnavailableView(
                        "No instances configured",
                        systemImage: "server.rack",
                        description: Text("Sign in to an analytics instance to browse its sites.")
                    )
                    .accessibilityIdentifier("site-picker-empty")
                } else {
                    ContentUnavailableView(
                        "No sites match",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different filter.")
                    )
                    .accessibilityIdentifier("site-picker-empty")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !visiblePinned.isEmpty {
                        Text("Pinned")
                            .font(.subheadline)
                            .bold()
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .accessibilityIdentifier("site-picker-pinned")
                        ForEach(visiblePinned, id: \.domain) { site in
                            siteRow(site)
                        }
                    }
                    ForEach(visibleSections, id: \.name) { section in
                        if visibleSections.count > 1 || !visiblePinned.isEmpty {
                            Text(section.name)
                                .font(.subheadline)
                                .bold()
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .accessibilityIdentifier("site-picker-team-\(section.name)")
                        }
                        ForEach(section.sites, id: \.domain) { site in
                            siteRow(site)
                        }
                    }
                }
            }
        }
        .task {
            await selection.loadAccounts()
        }
    }

    private func siteRow(_ site: SiteRef) -> some View {
        SiteRowView(
            site: site,
            account: selection.selectedAccount,
            pinned: selection.isPinned(site.domain),
            onSelect: { selection.selectSite(site.domain) },
            onTogglePin: {
                withAnimation(.snappy) {
                    selection.setPinned(site.domain, pinned: !selection.isPinned(site.domain))
                }
            },
            sparkline: sparkline
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var visiblePinned: [SiteRef] {
        filterSites(selection.pinnedSites)
    }

    private var visibleSections: [(name: String, sites: [SiteRef])] {
        let pinned = Set(selection.pinnedSites.map(\.domain))
        return selection.siteSections.compactMap { section in
            let rows = filterSites(section.sites).filter { !pinned.contains($0.domain) }
            return rows.isEmpty ? nil : (name: section.name, sites: rows)
        }
    }

    private func filterSites(_ sites: [SiteRef]) -> [SiteRef] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sites }
        return sites.filter { $0.domain.localizedCaseInsensitiveContains(query) }
    }
}
