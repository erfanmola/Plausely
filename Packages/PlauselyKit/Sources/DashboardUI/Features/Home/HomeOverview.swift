import AnalyticsCore
import SwiftUI

/// Live headcount hero: giant count over a green dot plus words (never
/// color alone). Morphs on every poll with a soft haptic tick.
public struct HomeHeroView: View {
    @Bindable private var model: RealtimeModel
    private let formatter = MetricFormatter()

    public init(model: RealtimeModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 6) {
            if let count = model.count {
                Text(formatter.string(for: .count(Int64(count)), as: .visitors))
                    .font(.system(size: 64, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: count)
                    .accessibilityIdentifier("home-hero-count")
            } else {
                ProgressView()
                    .accessibilityIdentifier("home-hero-loading")
            }
            Label("current visitors", systemImage: "circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .accessibilityIdentifier("home-hero-label")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-hero")
        .sensoryFeedback(.selection, trigger: model.count)
    }
}

/// Metric cards in reference style: pairs of white cards, gray centered
/// title, big black value with green/red arrow delta. Plain stacks only
/// (proven AX pattern); value/change/comparison ids match the legacy
/// overview so behavior tests keep passing.
public struct HomeMetricCards: View {
    private let overview: Overview
    private let formatter = MetricFormatter()

    public init(overview: Overview) {
        self.overview = overview
    }

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(cardPairs, id: \.first.metric) { pair in
                HStack(spacing: 12) {
                    metricCard(pair.first)
                    if let second = pair.second {
                        metricCard(second)
                    }
                }
            }
        }
    }

    private var cardPairs: [(first: TopStat, second: TopStat?)] {
        var pairs: [(TopStat, TopStat?)] = []
        var index = overview.stats.startIndex
        while index < overview.stats.endIndex {
            let first = overview.stats[index]
            let next = overview.stats.index(after: index)
            let second = next < overview.stats.endIndex ? overview.stats[next] : nil
            pairs.append((first, second))
            index = overview.stats.index(index, offsetBy: 2, limitedBy: overview.stats.endIndex) ?? overview.stats.endIndex
        }
        return pairs
    }

    private func metricCard(_ stat: TopStat) -> some View {
        VStack(spacing: 6) {
            Text(stat.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatter.string(for: stat.value, as: stat.metric))
                    .font(.title)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: stat.value)
                    .accessibilityIdentifier("overview-value-\(stat.metric.rawValue)")
                if let change = shortChangeText(stat.change) {
                    Text(change)
                        .font(.callout)
                        .foregroundStyle(changeDirectionColor(stat.change))
                        .accessibilityIdentifier("overview-change-\(stat.metric.rawValue)")
                }
            }
            if let comparison = stat.comparisonValue {
                Text("vs \(formatter.string(for: comparison, as: stat.metric))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("overview-comparison-\(stat.metric.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: HomeStyle.corner, style: .continuous))
        // Plain group: no identifier here — a parent-applied id (the
        // shared report-value stamp) would overwrite a group id, so tests
        // match the per-metric value/change/comparison ids inside.
        .accessibilityElement(children: .contain)
    }
}
