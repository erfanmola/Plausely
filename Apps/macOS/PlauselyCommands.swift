import SwiftUI

struct PlauselyCommands: Commands {
    var body: some Commands {
        CommandMenu("Plausely") {
            Button("Placeholder") {}
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
