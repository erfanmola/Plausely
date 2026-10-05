import CryptoKit
import Foundation

/// Site identity: dashboard domain plus the owning team when known.
/// Team scope comes from discovery; nil means undiscovered, never "no team".
public struct SiteID: Hashable, Codable, Sendable {
    public let domain: String
    public let teamID: String?
    public init(domain: String, teamID: String? = nil) {
        self.domain = domain
        self.teamID = teamID
    }
}

/// Immutable dashboard query. Every field participates in `QueryID` except
/// documented display-only choices. Validation rejects combinations the
/// server would silently reinterpret (comparison on realtime/all).
public struct DashboardQuery: Hashable, Sendable {
    public let accountID: AccountID
    public let siteID: SiteID
    public let period: Period
    public let periodDate: Date?
    public let comparison: Comparison
    public let matchDayOfWeek: Bool
    public let filters: FilterExpression
    public let includeImported: Bool
    public let interval: ChartInterval
    public let selectedMetric: MetricID
    public let timeZone: TimeZone

    public init(
        accountID: AccountID,
        siteID: SiteID,
        period: Period,
        periodDate: Date? = nil,
        comparison: Comparison = .off,
        matchDayOfWeek: Bool = true,
        filters: FilterExpression = .empty,
        includeImported: Bool = false,
        interval: ChartInterval,
        selectedMetric: MetricID,
        timeZone: TimeZone
    ) {
        self.accountID = accountID
        self.siteID = siteID
        self.period = period
        self.periodDate = periodDate
        self.comparison = comparison
        self.matchDayOfWeek = matchDayOfWeek
        self.filters = filters
        self.includeImported = includeImported
        self.interval = interval
        self.selectedMetric = selectedMetric
        self.timeZone = timeZone
    }

    public enum ValidationError: Error, Equatable {
        case comparisonUnsupportedForPeriod(Period)
        case intervalNotAllowed(ChartInterval, Period)
        case unresolvedCustomRange
    }

    /// Rejects query combinations the server would silently reinterpret.
    /// `policy` is the site's bootstrap interval map.
    public func validated(with policy: IntervalPolicy) throws {
        if comparison != .off, !comparison.isSupported(for: period) {
            throw ValidationError.comparisonUnsupportedForPeriod(period)
        }
        if !policy.isValid(interval, for: period) {
            throw ValidationError.intervalNotAllowed(interval, period)
        }
        if case .custom = period,
           SiteDateRules.range(for: period, periodDate: periodDate, timeZone: timeZone, today: Date()) == nil {
            throw ValidationError.unresolvedCustomRange
        }
    }
}

extension QueryID {
    /// Canonical identity: SHA-256 over stable JSON of every query field.
    /// Any semantic difference flips the ID; display formatting never does.
    /// `today` is injected so tests freeze period resolution.
    public static func compute(for query: DashboardQuery, today: Date) throws -> QueryID {
        let range = SiteDateRules.range(for: query.period, periodDate: query.periodDate, timeZone: query.timeZone, today: today)
        let comparisonRange: (from: Date, to: Date)?
        if query.comparison == .off {
            comparisonRange = nil
        } else if let range {
            comparisonRange = SiteDateRules.comparisonRange(
                for: query.comparison, primaryFrom: range.from, primaryTo: range.to, timeZone: query.timeZone
            )
        } else {
            comparisonRange = nil
        }
        let iso = { (date: Date) in SiteDateRules.isoDay(date, in: query.timeZone) }
        var document: [String: Any] = [
            "account": query.accountID.rawValue.uuidString,
            "domain": query.siteID.domain,
            "period": query.period.wireValue,
            "comparison": query.comparison.wireValue,
            "matchDayOfWeek": query.matchDayOfWeek,
            "filters": try query.filters.serialized(),
            "imported": query.includeImported,
            "interval": query.interval.rawValue,
            "metric": query.selectedMetric.rawValue,
            "timezone": query.timeZone.identifier,
        ]
        if let team = query.siteID.teamID { document["team"] = team }
        if let date = query.periodDate { document["periodDate"] = iso(date) }
        if let range { document["from"] = iso(range.from); document["to"] = iso(range.to) }
        if let comparisonRange {
            document["compareFrom"] = iso(comparisonRange.from)
            document["compareTo"] = iso(comparisonRange.to)
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = SHA256.hash(data: data)
        return QueryID(rawValue: digest.map { String(format: "%02x", $0) }.joined())
    }
}
