import Foundation

/// A single analytics value with explicit absence semantics.
///
/// Counts use `Int64`; ratios and averages keep server precision as `Decimal`
/// until rendering. A missing value is never decoded as zero — every absence
/// carries a reason. (Phase 02.1; DTO mapping lands in phase 03.)
/// Hashable so rows can travel through navigation values (05.2).
public enum MetricValue: Hashable, Sendable {
    case count(Int64)
    case decimal(Decimal)
    case unavailable(MetricUnavailableReason)

    /// True only for a real numeric zero. Unavailable values are never zero.
    public var isZero: Bool {
        switch self {
        case .count(let value): return value == 0
        case .decimal(let value): return value == 0
        case .unavailable: return false
        }
    }

    /// True when a renderable number exists.
    public var hasNumber: Bool {
        switch self {
        case .count, .decimal: return true
        case .unavailable: return false
        }
    }
}

/// Why a metric value is absent. Each maps to a distinct UI state.
public enum MetricUnavailableReason: String, Hashable, Sendable {
    /// Server returned null for this bucket/cell.
    case null
    /// Metric is not defined in this context (e.g. scroll depth off-page).
    case notDefined
    /// Metric is not supported for this report or server profile.
    case notSupported
    /// No data exists for this bucket (e.g. pre-launch dates).
    case noData
    /// Combining values is mathematically invalid (e.g. summing uniques).
    case nonAdditive
}

/// Rules for combining values. Server aggregates are always authoritative;
/// this helper exists only so invalid client-side math fails loudly instead
/// of producing plausible-looking wrong numbers.
public enum MetricMath {
    /// Sums values for an additive metric. Returns `.unavailable(.nonAdditive)`
    /// for non-additive metrics (unique visitors, visits, rates, averages).
    /// Nil buckets (plot gaps) are skipped.
    public static func total(_ values: [MetricValue?], for metric: MetricID) -> MetricValue {
        guard MetricID.descriptor(for: metric).additive else {
            return .unavailable(.nonAdditive)
        }
        var intTotal: Int64 = 0
        var decimalTotal = Decimal.zero
        var sawDecimal = false
        for value in values {
            switch value {
            case nil:
                continue
            case .count(let amount):
                if sawDecimal {
                    decimalTotal += Decimal(amount)
                } else {
                    intTotal += amount
                }
            case .decimal(let amount):
                if !sawDecimal {
                    sawDecimal = true
                    decimalTotal = Decimal(intTotal)
                }
                decimalTotal += amount
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        }
        return sawDecimal ? .decimal(decimalTotal) : .count(intTotal)
    }
}
