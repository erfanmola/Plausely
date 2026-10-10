import SwiftUI

/// Shimmer placeholder rows for loading states: content-shaped gray blocks
/// with a slow light sweep instead of a bare spinner holding the whole
/// surface. Static gray under Reduce Motion. Decorative: containers keep
/// their stable loading identifiers for tests and VoiceOver status.
public struct SkeletonBlocks: View {
    private let rows: Int
    private let rowHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    public init(rows: Int = 3, rowHeight: CGFloat = 16) {
        self.rows = rows
        self.rowHeight = rowHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0 ..< max(1, rows), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.secondary.opacity(0.16))
                    .frame(height: rowHeight)
                    .overlay {
                        if !reduceMotion {
                            GeometryReader { proxy in
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.6), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: proxy.size.width * 0.45)
                                .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.5)
                            }
                            .mask(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}
