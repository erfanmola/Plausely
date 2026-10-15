import AnalyticsCore
import SwiftUI

/// Demo root: the full dashboard over deterministic mock data, entered
/// from the login screen without signing in. Reads nothing from the
/// network or Keychain; per-site controls may persist example-domain
/// preferences in UserDefaults, which is harmless local-only state.
public struct DemoRootView: View {
    private let onExit: () -> Void

    public init(onExit: @escaping () -> Void = {}) {
        self.onExit = onExit
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label("Demo data", systemImage: "sparkles")
                Text("Sign in to see your own stats.")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Exit", action: onExit)
                    .accessibilityIdentifier("demo-exit")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.quaternary)
            .accessibilityIdentifier("demo-banner")
            HomeRootView(
                directory: MockSiteDirectory.thirteenSites(),
                overviewLoader: MockOverviewProviders.overview,
                seriesLoader: MockOverviewProviders.series,
                breakdownLoader: MockBreakdownProviders.loader,
                suggestions: MockQueryProviders.suggestions,
                segmentList: MockQueryProviders.segments,
                realtimeLoader: MockRealtimeProviders.count,
                onExport: { _ in (filename: "mock-export.zip", data: MockExportProviders.payload) }
            )
        }
        .tint(AppAppearance.shared.accent.top)
        .preferredColorScheme(AppAppearance.shared.theme.scheme)
        .accessibilityIdentifier("demo-root")
    }
}
