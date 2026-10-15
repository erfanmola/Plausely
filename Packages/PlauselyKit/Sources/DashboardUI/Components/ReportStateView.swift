import AnalyticsCore
import SwiftUI

/// Consistent rendering of every report state: idle/loading/empty/value/
/// error/unsupported. Loading always reads as shimmer into fresh data;
/// failed refreshes keep the last good value above the error. Retry is
/// always offered on failure. Accessibility identifiers are stable.
public struct ReportStateView<Value: Sendable, Content: View, Skeleton: View>: View {
    private let state: ReportLoadState<Value>
    private let onRetry: () -> Void
    private let skeleton: () -> Skeleton
    private let content: (ReportEnvelope<Value>) -> Content

    public init(
        state: ReportLoadState<Value>,
        onRetry: @escaping () -> Void = {},
        @ViewBuilder skeleton: @escaping () -> Skeleton,
        @ViewBuilder content: @escaping (ReportEnvelope<Value>) -> Content
    ) {
        self.state = state
        self.onRetry = onRetry
        self.skeleton = skeleton
        self.content = content
    }

    public var body: some View {
        Group {
            switch state {
            case .idle:
                ProgressView()
                    .accessibilityIdentifier("report-idle")
            case .loading:
                // Skeleton only, even when a stale envelope exists: the
                // refresh reads as shimmer into fresh data, never old data
                // wearing a badge.
                skeleton()
                    .accessibilityIdentifier("report-loading")
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
                        content(stale)
                    }
                    ContentUnavailableView {
                        Label(error.message, systemImage: "exclamationmark.triangle")
                            .accessibilityIdentifier("report-error")
                    } description: {
                        Text("Check the connection and try again.")
                    } actions: {
                        Button("Retry", action: onRetry)
                            .accessibilityIdentifier("report-retry")
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .unsupported(let reason):
                ContentUnavailableView(
                    "Not available",
                    systemImage: "eye.slash",
                    description: Text(reason)
                )
                .accessibilityIdentifier("report-unsupported")
            }
        }
    }
}

/// Back-compat constructor with the generic loading shimmer. Call sites
/// with content-shaped skeletons use the full initializer instead.
public extension ReportStateView where Skeleton == SkeletonBlocks {
    init(
        state: ReportLoadState<Value>,
        onRetry: @escaping () -> Void = {},
        @ViewBuilder content: @escaping (ReportEnvelope<Value>) -> Content
    ) {
        self.init(
            state: state, onRetry: onRetry,
            skeleton: { SkeletonBlocks(rows: 6, rowHeight: 22) },
            content: content
        )
    }
}
