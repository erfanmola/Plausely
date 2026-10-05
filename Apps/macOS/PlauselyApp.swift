import DashboardUI
import SwiftUI

@main
struct PlauselyApp: App {
    var body: some Scene {
        WindowGroup {
            BootstrapView()
        }
        .commands {
            PlauselyCommands()
        }
    }
}
