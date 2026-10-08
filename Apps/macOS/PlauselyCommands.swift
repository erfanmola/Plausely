import SwiftUI

/// Shell commands: the standard sidebar menu. Kept as its own type so future
/// shell commands (refresh, per-window actions) have one home.
struct PlauselyCommands: Commands {
    var body: some Commands {
        SidebarCommands()
    }
}
