import DashboardUI
import SwiftUI

/// Shell commands: the standard sidebar menu plus the dashboard menu.
/// Refresh (⌘R) invokes the focused window's refresh action; it stays
/// disabled where no dashboard is open (login, picker).
struct PlauselyCommands: Commands {
    @FocusedValue(\.plauselyRefresh) private var refresh

    var body: some Commands {
        SidebarCommands()
        CommandMenu("Dashboard") {
            Button("Refresh") {
                Task { await refresh?.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refresh == nil)
        }
    }
}
