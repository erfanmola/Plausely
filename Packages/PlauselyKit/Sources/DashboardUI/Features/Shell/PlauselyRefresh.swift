import SwiftUI

/// Window-wide dashboard refresh for menu commands (⌘R on macOS).
/// Roots publish one through `.focusedValue`; `PlauselyCommands` invokes
/// the focused window's action. Async refresh work runs in the caller's
/// task; the action itself only captures MainActor-isolated models.
public struct PlauselyRefreshAction: Sendable {
    public let refresh: @MainActor @Sendable () async -> Void

    public init(refresh: @MainActor @Sendable @escaping () async -> Void) {
        self.refresh = refresh
    }
}

private struct PlauselyRefreshKey: FocusedValueKey {
    typealias Value = PlauselyRefreshAction
}

public extension FocusedValues {
    var plauselyRefresh: PlauselyRefreshAction? {
        get { self[PlauselyRefreshKey.self] }
        set { self[PlauselyRefreshKey.self] = newValue }
    }
}
