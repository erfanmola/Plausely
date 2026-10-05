import Foundation

/// Calendar date math in a site's IANA timezone. Every function takes the
/// site timezone and an explicit "today" so tests freeze time; production
/// passes the current date. The device timezone is never consulted.
///
/// Ranges are inclusive on both ends (server `from`/`to` semantics).
/// Custom comparison ranges may differ in length from the primary range.
public enum SiteDateRules {
    /// Start of the calendar day containing `date` in `timeZone`.
    public static func startOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    /// Resolves a period to an inclusive [from, to] day range.
    /// - `periodDate` anchors relative presets (day/month arrows); nil means today.
    public static func range(
        for period: Period,
        periodDate: Date? = nil,
        timeZone: TimeZone,
        today: Date
    ) -> (from: Date, to: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let anchorDay = startOfDay(periodDate ?? today, in: timeZone)

        switch period {
        case .realtime:
            return nil
        case .day:
            return (anchorDay, anchorDay)
        case .month:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: anchorDay))!
            return (start, anchorDay)
        case .year:
            let start = calendar.date(from: DateComponents(
                year: calendar.component(.year, from: anchorDay), month: 1, day: 1
            ))!
            return (start, anchorDay)
        case .all:
            return nil
        case .custom(let from, let to):
            let fromDay = startOfDay(from, in: timeZone)
            let toDay = startOfDay(to, in: timeZone)
            guard fromDay <= toDay else { return nil }
            return (fromDay, toDay)
        case .months6, .months12:
            let months = period == .months6 ? 6 : 12
            let startMonth = calendar.date(byAdding: .month, value: -(months - 1), to: anchorDay)!
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: startMonth))!
            return (start, anchorDay)
        default:
            guard let length = period.fixedLengthInDays else { return nil }
            let start = calendar.date(byAdding: .day, value: -(length - 1), to: anchorDay)!
            return (start, anchorDay)
        }
    }

    /// Resolves the comparison range for a primary range. Previous-period
    /// shifts back by the primary length (proven live: 7-day window shifted
    /// exactly 7 days). Year-over-year shifts one calendar year. Custom ranges
    /// pass through even when lengths differ.
    public static func comparisonRange(
        for comparison: Comparison,
        primaryFrom: Date,
        primaryTo: Date,
        timeZone: TimeZone
    ) -> (from: Date, to: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch comparison {
        case .off:
            return nil
        case .previousPeriod:
            let length = calendar.dateComponents([.day], from: primaryFrom, to: primaryTo).day! + 1
            let from = calendar.date(byAdding: .day, value: -length, to: primaryFrom)!
            let to = calendar.date(byAdding: .day, value: -length, to: primaryTo)!
            return (from, to)
        case .yearOverYear:
            let from = calendar.date(byAdding: .year, value: -1, to: primaryFrom)!
            let to = calendar.date(byAdding: .year, value: -1, to: primaryTo)!
            return (from, to)
        case .custom(let from, let to):
            return from <= to ? (from, to) : nil
        }
    }

    /// ISO calendar-day string (`yyyy-MM-dd`) in the site timezone.
    public static func isoDay(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
