import AnalyticsCore
import Foundation

/// Persisted per-site query controls: period, comparison, and toggles.
/// Wire strings plus ISO dates (never live model types), so stored state
/// survives code changes. Interval is deliberately absent — it always
/// re-derives from the site bootstrap policy.
public struct StoredControls: Codable, Equatable, Sendable {
    public var period: String
    public var periodDate: Date?
    public var customFrom: Date?
    public var customTo: Date?
    public var comparison: String
    public var comparisonFrom: Date?
    public var comparisonTo: Date?
    public var matchDayOfWeek: Bool
    public var includeImported: Bool

    public init(
        period: String = "28d",
        periodDate: Date? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil,
        comparison: String = "off",
        comparisonFrom: Date? = nil,
        comparisonTo: Date? = nil,
        matchDayOfWeek: Bool = true,
        includeImported: Bool = false
    ) {
        self.period = period
        self.periodDate = periodDate
        self.customFrom = customFrom
        self.customTo = customTo
        self.comparison = comparison
        self.comparisonFrom = comparisonFrom
        self.comparisonTo = comparisonTo
        self.matchDayOfWeek = matchDayOfWeek
        self.includeImported = includeImported
    }

    /// Rebuilds the period, falling back to 28 days for unknown values.
    public func makePeriod(calendar: Calendar = Calendar(identifier: .gregorian)) -> Period {
        switch period {
        case "realtime": return .realtime
        case "day": return .day
        case "month": return .month
        case "7d": return .days7
        case "28d": return .days28
        case "30d": return .days30
        case "91d": return .days91
        case "6mo": return .months6
        case "12mo": return .months12
        case "year": return .year
        case "all": return .all
        case "custom":
            if let customFrom, let customTo, customFrom <= customTo {
                return .custom(from: customFrom, to: customTo)
            }
            return .days28
        default: return .days28
        }
    }

    /// Rebuilds the comparison, sanitized against the period (an
    /// unsupported pairing degrades to off rather than an error state).
    public func makeComparison(for resolved: Period) -> Comparison {
        let candidate: Comparison
        switch comparison {
        case "previous_period": candidate = .previousPeriod
        case "year_over_year": candidate = .yearOverYear
        case "custom":
            if let comparisonFrom, let comparisonTo, comparisonFrom <= comparisonTo {
                candidate = .custom(from: comparisonFrom, to: comparisonTo)
            } else {
                candidate = .off
            }
        default: candidate = .off
        }
        return candidate.isSupported(for: resolved) ? candidate : .off
    }
}

/// Per-site preferences plus last active site, persisted locally.
/// Callers inject an ephemeral suite in tests. Main-actor confined
/// through its owners.
public struct SitePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func controlsKey(account: AccountID, domain: String) -> String {
        "plausely.controls.\(account.rawValue.uuidString).\(domain)"
    }

    public func controls(account: AccountID, domain: String) -> StoredControls? {
        guard let data = defaults.data(forKey: controlsKey(account: account, domain: domain)) else { return nil }
        return try? JSONDecoder().decode(StoredControls.self, from: data)
    }

    public func saveControls(_ controls: StoredControls, account: AccountID, domain: String) {
        guard let data = try? JSONEncoder().encode(controls) else { return }
        defaults.set(data, forKey: controlsKey(account: account, domain: domain))
    }

    public struct LastSite: Codable, Equatable, Sendable {
        public let account: UUID
        public let domain: String
        public init(account: UUID, domain: String) {
            self.account = account
            self.domain = domain
        }
    }

    public func lastSite() -> LastSite? {
        guard let data = defaults.data(forKey: "plausely.lastSite") else { return nil }
        return try? JSONDecoder().decode(LastSite.self, from: data)
    }

    public func saveLastSite(account: AccountID, domain: String) {
        let record = LastSite(account: account.rawValue, domain: domain)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: "plausely.lastSite")
    }
}

extension StoredControls {
    /// Snapshots a working model for per-site persistence. Interval is
    /// intentionally omitted (it re-derives from policy); clauses stay
    /// out (filters are session state, not preferences).
    @MainActor
    init(model: QueryModel) {
        period = model.period.wireValue
        periodDate = model.periodDate
        if case .custom(let from, let to) = model.period {
            customFrom = from
            customTo = to
        } else {
            customFrom = nil
            customTo = nil
        }
        switch model.comparison {
        case .off:
            comparison = "off"
            comparisonFrom = nil
            comparisonTo = nil
        case .previousPeriod:
            comparison = "previous_period"
            comparisonFrom = nil
            comparisonTo = nil
        case .yearOverYear:
            comparison = "year_over_year"
            comparisonFrom = nil
            comparisonTo = nil
        case .custom(let from, let to):
            comparison = "custom"
            comparisonFrom = from
            comparisonTo = to
        }
        matchDayOfWeek = model.matchDayOfWeek
        includeImported = model.includeImported
    }
}
