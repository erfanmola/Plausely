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

    /// Dashboard-faithful current interval (mirrors `interval-picker.tsx`
    /// `getCurrentInterval`): keep `current` when valid for the period;
    /// otherwise fall back to the dashboard default. The bootstrap map
    /// stays authoritative for validity; the default table only picks
    /// among valid entries.
    public func currentInterval(
        _ current: ChartInterval,
        for period: Period,
        periodDate: Date? = nil,
        timeZone: TimeZone,
        today: Date = Date()
    ) -> ChartInterval {
        let options = validIntervals(for: period, periodDate: periodDate, timeZone: timeZone, today: today)
        if options.contains(current) { return current }
        if let fallback = defaultInterval(for: period, periodDate: periodDate, timeZone: timeZone, today: today),
           options.contains(fallback) { return fallback }
        return options.first ?? current
    }

    /// Valid intervals for a period: the custom-range rule, else the
    /// bootstrap map entry.
    public func validIntervals(
        for period: Period,
        periodDate: Date? = nil,
        timeZone: TimeZone,
        today: Date = Date()
    ) -> [ChartInterval] {
        if case .custom(let from, let to) = period {
            return customOptions(from: from, to: to, timeZone: timeZone)
        }
        return validByPeriod[period.wireValue] ?? []
    }

    /// Dashboard default per period (`defaultByPeriod` + custom rule),
    /// nil when the map alone decides (first valid wins).
    public func defaultInterval(
        for period: Period,
        periodDate: Date? = nil,
        timeZone: TimeZone,
        today: Date = Date()
    ) -> ChartInterval? {
        switch period {
        case .realtime: return .minute
        case .day: return .hour
        case .days7: return .day
        case .months6, .months12, .year: return .month
        case .custom(let from, let to):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
            let months = calendar.dateComponents([.month], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).month ?? 0
            if days < 30 { return .day }
            if months < 6 { return .week }
            return .month
        default: return nil
        }
    }

    /// Custom-range options by span (`validIntervals` custom branch).
    private func customOptions(from: Date, to: Date, timeZone: TimeZone) -> [ChartInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
        let months = calendar.dateComponents([.month], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).month ?? 0
        if days < 7 { return [.day] }
        if months < 1 { return [.day, .week] }
        if months < 12 { return [.day, .week, .month] }
        return [.week, .month]
    }
}
