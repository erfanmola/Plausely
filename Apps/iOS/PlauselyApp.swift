import DashboardUI
import SwiftUI

@main
struct PlauselyApp: App {
    /// Deterministic mock launch for UI smoke tests. Real dependency
    /// injection lands with feature work; this flag only swaps the root.
    static var isMockLaunch: Bool {
        CommandLine.arguments.contains("-plausely-mock")
    }

    var body: some Scene {
        WindowGroup {
            if Self.isMockLaunch {
                Text("Mock")
            } else {
                BootstrapView()
            }
        }
    }
}
