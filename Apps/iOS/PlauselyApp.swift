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
                HomeRootView(
                    directory: Self.directory,
                    overviewLoader: MockOverviewProviders.overview,
                    seriesLoader: MockOverviewProviders.series,
                    breakdownLoader: MockBreakdownProviders.loader,
                    suggestions: MockQueryProviders.suggestions,
                    segmentList: MockQueryProviders.segments,
                    realtimeLoader: MockRealtimeProviders.count,
                    onExport: { _ in (filename: "mock-export.zip", data: MockExportProviders.payload) },
                    resolvePolicy: { _ in MockQueryProviders.intervals }
                )
            } else {
                LiveRootView()
            }
        }
    }
}

