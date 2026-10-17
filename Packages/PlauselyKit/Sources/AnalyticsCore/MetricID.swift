import Foundation

/// Metrics exposed by stock CE 3.2.1 dashboard reports. Raw values match the
/// server's metric keys so phase-03 DTOs can map without guessing.
public enum MetricID: String, Hashable, Codable, Sendable, CaseIterable {
    case visitors
    case visits
    case pageviews
    case viewsPerVisit = "views_per_visit"
    case bounceRate = "bounce_rate"
    case visitDuration = "visit_duration"
    case events
    case conversions
    case conversionRate = "conversion_rate"
    case groupConversionRate = "group_conversion_rate"
    case timeOnPage = "time_on_page"
    case scrollDepth = "scroll_depth"
    case percentage
    case entrances
    case exits
    case exitRate = "exit_rate"
    case samplePercent = "sample_percent"
    case impressions
    case ctr
    case position
    case totalRevenue = "total_revenue"
    case averageRevenue = "average_revenue"

    public struct Descriptor: Equatable, Sendable {
        /// Display name shown in metric pickers (sentence case, no values).
        public let displayName: String
        public let unit: Unit
        /// Whether values may be summed across buckets. Only strictly additive
        /// event/page counts qualify; unique visitors, visits, ratios and
        /// averages must always come from server aggregates.
        public let additive: Bool
    }

    public enum Unit: Equatable, Sendable {
        case count
        case percent
        case seconds
        case ratio
    }

    public static func descriptor(for metric: MetricID) -> Descriptor {
        switch metric {
        case .visitors:
            return Descriptor(displayName: "Unique visitors", unit: .count, additive: false)
        case .visits:
            return Descriptor(displayName: "Total visits", unit: .count, additive: false)
        case .pageviews:
            return Descriptor(displayName: "Total pageviews", unit: .count, additive: true)
        case .viewsPerVisit:
            return Descriptor(displayName: "Views per visit", unit: .ratio, additive: false)
        case .bounceRate:
            return Descriptor(displayName: "Bounce rate", unit: .percent, additive: false)
        case .visitDuration:
            return Descriptor(displayName: "Visit duration", unit: .seconds, additive: false)
        case .events:
            return Descriptor(displayName: "Total events", unit: .count, additive: true)
        case .conversions:
            return Descriptor(displayName: "Total conversions", unit: .count, additive: true)
        case .conversionRate:
            return Descriptor(displayName: "Conversion rate", unit: .percent, additive: false)
        case .groupConversionRate:
            return Descriptor(displayName: "Group conversion rate", unit: .percent, additive: false)
        case .timeOnPage:
            return Descriptor(displayName: "Time on page", unit: .seconds, additive: false)
        case .scrollDepth:
            return Descriptor(displayName: "Scroll depth", unit: .percent, additive: false)
        case .percentage:
            return Descriptor(displayName: "Percentage", unit: .percent, additive: false)
        case .entrances:
            return Descriptor(displayName: "Entrances", unit: .count, additive: true)
        case .exits:
            return Descriptor(displayName: "Exits", unit: .count, additive: true)
        case .exitRate:
            return Descriptor(displayName: "Exit rate", unit: .percent, additive: false)
        case .samplePercent:
            return Descriptor(displayName: "Sample", unit: .percent, additive: false)
        case .impressions:
            return Descriptor(displayName: "Impressions", unit: .count, additive: true)
        case .ctr:
            return Descriptor(displayName: "CTR", unit: .percent, additive: false)
        case .position:
            return Descriptor(displayName: "Position", unit: .ratio, additive: false)
        case .totalRevenue:
            // Server values are plain numbers (no currency code in the
            // top-stats payload), so this renders as a decimal amount.
            return Descriptor(displayName: "Total revenue", unit: .ratio, additive: true)
        case .averageRevenue:
            return Descriptor(displayName: "Average revenue", unit: .ratio, additive: false)
        }
    }
}
