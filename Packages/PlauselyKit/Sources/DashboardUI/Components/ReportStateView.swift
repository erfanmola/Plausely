import AnalyticsCore
import SwiftUI

/// Consistent rendering of every report state: idle/loading/empty/value/
/// error/unsupported. A stale envelope stays visible beneath loading and
/// failed states with an explicit stale marker; retry is always offered on
/// failure. Accessibility identifiers are stable for UI tests.
public struct ReportStateView<Value: Sendable, Content: View>: View {
    private let state: ReportLoadState<Value>
    private let onRetry: () -> Void
    private let content: (ReportEnvelope<Value>) -> Content

    public init(
        state: ReportLoadState<Value>,
        onRetry: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (ReportEnvelope<Value>) -> Content
    ) {
        self.state = state
        self.onRetry = onRetry
        self.content = content
    }

    public var body: some View {
        Group {
            switch state {
            case .idle:
                Text("Not loaded")
                    .accessibilityIdentifier("report-idle")
            case .loading(let stale):
                VStack {
                    ProgressView()
                        .accessibilityIdentifier("report-loading")
                    if let stale {
                        staleBadge
                        content(stale)
                    }
                }
            case .loaded(let envelope):
                content(envelope)
                    .accessibilityIdentifier("report-value")
            case .empty:
                ContentUnavailableView(
                    "No data for this period",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Values appear here once the site collects matching traffic.")
                )
                .accessibilityIdentifier("report-empty")
            case .failed(let error, let stale):
                VStack {
                    if let stale {
                        staleBadge
                        content(stale)
                    }
                    Text(error.message)
                        .accessibilityIdentifier("report-error")
                    Button("Retry", action: onRetry)
                        .accessibilityIdentifier("report-retry")
                }
            case .unsupported(let reason):
                Text(reason)
                    .accessibilityIdentifier("report-unsupported")
            }
        }
    }

    private var staleBadge: some View {
        Label("Showing last loaded data", systemImage: "arrow.clockwise")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule(style: .continuous))
            .accessibilityIdentifier("report-stale")
    }
}
