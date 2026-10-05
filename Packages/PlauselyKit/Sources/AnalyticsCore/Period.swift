import Foundation

/// Dashboard periods. Raw values match the pinned dashboard's `QueryPeriod`.
public enum Period: Hashable, Sendable {
    case realtime
    case day
    case month
    case days7
    case days28
    case days30
    case days91
    case months6
    case months12
    case year
    case all
    case custom(from: Date, to: Date)

    public var wireValue: String {
        switch self {
        case .realtime: return "realtime"
        case .day: return "day"
        case .month: return "month"
        case .days7: return "7d"
        case .days28: return "28d"
        case .days30: return "30d"
        case .days91: return "91d"
        case .months6: return "6mo"
        case .months12: return "12mo"
        case .year: return "year"
        case .all: return "all"
        case .custom: return "custom"
        }
    }

    /// Lookback length in days for fixed windows (inclusive ranges).
    var fixedLengthInDays: Int? {
        switch self {
        case .day: return 1
        case .days7: return 7
        case .days28: return 28
        case .days30: return 30
        case .days91: return 91
        default: return nil
        }
    }
}

/// Comparison modes. Raw values match `ComparisonMode` on the dashboard.
public enum Comparison: Hashable, Sendable {
    case off
    case previousPeriod
    case yearOverYear
    case custom(from: Date, to: Date)

    public var wireValue: String {
        switch self {
        case .off: return "off"
        case .previousPeriod: return "previous_period"
        case .yearOverYear: return "year_over_year"
        case .custom: return "custom"
        }
    }

    /// The dashboard disables comparisons for realtime and all-time.
    public func isSupported(for period: Period) -> Bool {
        switch period {
        case .realtime, .all: return false
        default: return true
        }
    }
}

/// Chart intervals. Allowed values per period come from the site bootstrap
/// (`data-valid-intervals-by-period`), never hardcoded.
public enum ChartInterval: String, Hashable, Codable, Sendable {
    case minute
    case hour
    case day
    case week
    case month
}

/// Interval policy decoded from one site's bootstrap map.
public struct IntervalPolicy: Hashable, Sendable {
    public let validByPeriod: [String: [ChartInterval]]
    public init(validByPeriod: [String: [ChartInterval]]) {
        self.validByPeriod = validByPeriod
    }

    public func isValid(_ interval: ChartInterval, for period: Period) -> Bool {
        validByPeriod[period.wireValue]?.contains(interval) ?? false
    }
}
