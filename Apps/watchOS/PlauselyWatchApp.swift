import SwiftUI

/// Companion watch app entry. Thin client over the iPhone: `WatchRootView`
/// renders picker/overview/breakdowns from `WatchSessionManager`, which
/// proxies every request through the phone's `LiveHub`.
@main
struct PlauselyWatchApp: App {
    @State private var link = WatchSessionManager()

    var body: some Scene {
        WindowGroup {
            WatchRootView(link: link)
        }
    }
}
