import AnalyticsCore
import SwiftUI

/// Deterministic headcount loader for UI tests and previews. Production
/// loaders arrive with the client wiring; nothing here touches the network.
public enum MockRealtimeProviders {
    public static var count: RealtimeModel.CountLoader {
        { _, _ in 42 }
    }
}

/// Live headcount badge: green dot plus words (never color alone), exact
/// count with morphing digits, haptic tick on change. Failures keep the
/// last count and say so; the badge never shows zero for an error.
public struct RealtimeBadge: View {
    @Bindable private var model: RealtimeModel

    public init(model: RealtimeModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.count == nil && model.errorMessage != nil ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            if let count = model.count {
                Text("\(count) online now")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: count)
                    .accessibilityIdentifier("realtime-count")
            } else if model.errorMessage != nil {
                Text("Live count unavailable")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("realtime-unavailable")
            } else {
                ProgressView()
                    .scaleEffect(0.7)
                    .accessibilityIdentifier("realtime-loading")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.count.map { "\($0) visitors online now" } ?? "Live visitors unavailable")
        .accessibilityIdentifier("realtime-badge")
        .sensoryFeedback(.selection, trigger: model.count)
    }
}
