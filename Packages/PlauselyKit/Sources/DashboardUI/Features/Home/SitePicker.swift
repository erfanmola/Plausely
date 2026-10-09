import AnalyticsCore
import SwiftUI

/// Domain monogram: first letter on a stable tinted squircle. Offline and
/// deterministic (stable hash, never `hashValue`), so a site keeps its
/// mark across launches. Decorative; rows carry the accessible names.
struct SiteMonogram: View {
    let domain: String
    private static let tints: [Color] = [.blue, .green, .orange, .red, .teal, .pink, .cyan, .mint, .brown]

    var body: some View {
        Text(letter)
            .font(.headline)
            .bold()
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    private var letter: String {
        domain.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
    }

    private var tint: Color {
        var hash = 5381
        for scalar in domain.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return Self.tints[abs(hash) % Self.tints.count]
    }
}

/// Elegant site picker for the unselected state (and anywhere a full
/// list beats a menu): team sections, monograms, role meta, inline
/// filter for long lists. Selecting a site builds its query; account
/// switching stays in the header menu and Settings.
struct SitePickerView: View {
    @Bindable var selection: SiteSelectionModel
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
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
                HStack {
                    ProgressView()
                    Text("Loading sites…")
                        .foregroundStyle(.secondary)
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
            } else if visibleSections.isEmpty {
                Text(selection.accounts.isEmpty ? "No instances configured." : "No sites match.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("site-picker-empty")
            } else {
                ForEach(visibleSections, id: \.name) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        if visibleSections.count > 1 {
                            Text(section.name)
                                .font(.subheadline)
                                .bold()
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .accessibilityIdentifier("site-picker-team-\(section.name)")
                        }
                        ForEach(section.sites, id: \.domain) { site in
                            Button {
                                selection.selectSite(site.domain)
                            } label: {
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
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("site-option-\(site.domain)")
                        }
                    }
                }
            }
        }
        .task {
            await selection.loadAccounts()
        }
    }

    private var visibleSections: [(name: String, sites: [SiteRef])] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return selection.siteSections }
        return selection.siteSections.compactMap { section in
            let rows = section.sites.filter { $0.domain.localizedCaseInsensitiveContains(query) }
            return rows.isEmpty ? nil : (name: section.name, sites: rows)
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
