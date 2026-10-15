import SwiftUI

/// Shimmer sweep overlay for one solid placeholder shape: a slow light
/// band clipped to the host shape, static under Reduce Motion. Applied
/// per solid shape only — never on containers — so the band can't bleed
/// into transparent gaps between shapes.
struct ShimmerSweep: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 8) {
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content.overlay {
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
                .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

/// Shimmer placeholder rows for loading states: content-shaped gray blocks
/// with a slow light sweep instead of a bare spinner holding the whole
/// surface. Static gray under Reduce Motion. Decorative: containers keep
/// their stable loading identifiers for tests and VoiceOver status.
public struct SkeletonBlocks: View {
    private let rows: Int
    private let rowHeight: CGFloat

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
                    .modifier(ShimmerSweep(cornerRadius: 8))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One gray shimmer bar. Widths are representative (real text widths are
/// unknowable before load); heights, radii, and positions match the
/// component the bar stands in for.
struct SkeletonBar: View {
    private let width: CGFloat?
    private let height: CGFloat
    private let cornerRadius: CGFloat

    init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = 8) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.secondary.opacity(0.16))
            .frame(width: width, height: height)
            .modifier(ShimmerSweep(cornerRadius: cornerRadius))
    }
}

/// Live-headcount hero skeleton: mirrors HomeHeroView geometry exactly —
/// 30pt dot slot, number-sized bar for the 56pt count, centered label bar
/// for "current visitors" — so the hero never shifts when the count lands.
public struct HeroSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(.secondary.opacity(0.16))
                    .frame(width: 12, height: 12)
                    .frame(width: 30, height: 30)
                SkeletonBar(width: 116, height: 68, cornerRadius: 12)
                Color.clear
                    .frame(width: 30, height: 30)
            }
            SkeletonBar(width: 150, height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityHidden(true)
    }
}

/// Metric-cards skeleton: mirrors HomeMetricCards geometry — three pairs
/// of corner-22 cards with centered title/value/comparison bars — so cards
/// never resize when the stats land.
public struct MetricCardsSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(0 ..< 3, id: \.self) { _ in
                HStack(spacing: 12) {
                    ForEach(0 ..< 2, id: \.self) { _ in
                        VStack(spacing: 6) {
                            SkeletonBar(width: 90, height: 20)
                            SkeletonBar(width: 110, height: 36)
                            SkeletonBar(width: 70, height: 18)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            HomeStyle.card,
                            in: RoundedRectangle(cornerRadius: HomeStyle.corner, style: .continuous)
                        )
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Series-chart skeleton: a 150pt block matching the chart frame inside
/// its card, so the card never collapses while the series loads. The
/// Today estimate caption reserves its slot when requested, so its late
/// arrival never pushes content down.
public struct ChartSkeleton: View {
    private let reserveCaption: Bool

    public init(reserveCaption: Bool = false) {
        self.reserveCaption = reserveCaption
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            SkeletonBar(height: 150, cornerRadius: 12)
                .frame(minHeight: 150)
            if reserveCaption {
                Color.clear.frame(height: 14)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Breakdown-summary skeleton: full-width 46pt capsules matching the
/// proportional-bar rows one-for-one (same count, spacing, and height),
/// so rows never jump when values land. Widths stay full: per-row shares
/// are unknowable before load.
public struct SummaryRowsSkeleton: View {
    private let rows: Int

    public init(rows: Int = 5) {
        self.rows = rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0 ..< max(1, rows), id: \.self) { _ in
                Capsule(style: .continuous)
                    .fill(.secondary.opacity(0.16))
                    .frame(height: 46)
                    .modifier(ShimmerSweep(cornerRadius: 23))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Site-row skeleton: mirrors SiteRowView geometry — 40pt monogram tile,
/// two text bars, pin slot, 4pt vertical padding, then the 30pt sparkline
/// slot — so picker rows never shift when sites and previews land.
public struct SiteRowSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SkeletonBar(width: 40, height: 40, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    SkeletonBar(width: 170, height: 22)
                    SkeletonBar(width: 110, height: 16)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(.secondary.opacity(0.16))
                    .frame(width: 21, height: 21)
                    .frame(minWidth: 44, minHeight: 44)
            }
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.secondary.opacity(0.1))
                .frame(height: 30)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// Top-stats list skeleton (macOS shell): mirrors TopStatsGrid rows —
/// 34pt tile plus name/value/comparison bars — so the list never shifts
/// when headline numbers land.
public struct TopStatsSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0 ..< 6, id: \.self) { _ in
                HStack(spacing: 10) {
                    SkeletonBar(width: 34, height: 34, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        SkeletonBar(width: 100, height: 15)
                        SkeletonBar(width: 130, height: 22)
                        SkeletonBar(width: 80, height: 15)
                        SkeletonBar(width: 90, height: 15)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Boot skeleton: mirrors the site picker (the common first paint) — a
/// title block plus monogram rows — instead of anonymous bars.
public struct BootSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBar(width: 170, height: 26)
            SkeletonBar(width: 240, height: 19)
            ForEach(0 ..< 4, id: \.self) { _ in
                SiteRowSkeleton()
            }
        }
        .accessibilityHidden(true)
    }
}
