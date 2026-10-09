import AnalyticsCore
import Foundation

/// Typed control failure. Invalid selections never reach the wire: the model
/// keeps the last good effective query and reports what was rejected.
public enum QueryControlError: Error, Equatable, Sendable {
    case multipleGoalFilters
    case multipleSegments
    case invalidSegmentValues
    case comparisonUnsupported(period: String)
    case emptyCustomRange
    case emptyComparisonRange
    case filterInvalid(String)
}

/// One saved segment: server-stored filter set applied read-only. Mutations
/// (create/update/delete) belong to phase 08; 04.3 lists and applies only.
public struct SavedSegment: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case personal
        case site
    }

    public let id: Int
    public let name: String
    public let kind: Kind
    public let filters: FilterExpression

    public init(id: Int, name: String, kind: Kind, filters: FilterExpression = FilterExpression()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.filters = filters
    }
}

/// One suggestion row for a filter value field.
public struct Suggestion: Hashable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public typealias SuggestionProvider = @Sendable (SuggestionRequest, Date) async throws -> [Suggestion]
public typealias SegmentListProvider = @Sendable (DashboardQuery) async throws -> [SavedSegment]

/// Segment list load state for the read-only picker.
public enum SegmentLoadState: Sendable {
    case unconfigured
    case loading
    case loaded([SavedSegment])
    case failed(ReportLoadError)
}

/// Editable working copy over one immutable base query. Every mutation
/// revalidates synchronously: `effective` holds the exact query to run (or
/// nil with `error` explaining the rejection). Locked filters (shared-link
/// scope) merge into every effective query and can never be edited here.
@MainActor
@Observable
public final class QueryModel {
    public private(set) var base: DashboardQuery
    public var period: Period
    public var periodDate: Date?
    public var comparison: Comparison = .off
    public var matchDayOfWeek = true
    public var includeImported = false
    /// Chart interval, conformed to the site's bootstrap policy on every
    /// refresh: a stale interval from a previous period never reaches the
    /// wire (the dashboard re-derives it the same way on period change).
    public private(set) var interval: ChartInterval
    /// User-editable clauses. Locked clauses ride `locked`, never this list.
    public private(set) var clauses: [FilterClause] = []
    public var locked = FilterExpression() {
        didSet { refresh() }
    }

    public private(set) var effective: DashboardQuery?
    public private(set) var error: QueryControlError?
    public private(set) var segmentsState: SegmentLoadState = .unconfigured
    public private(set) var appliedSegmentID: Int?

    private let suggestions: SuggestionProvider?
    private let segmentList: SegmentListProvider?
    private let intervalPolicy: IntervalPolicy?
    private let clock: @Sendable () -> Date
    private var appliedSegmentClauses: [FilterClause] = []
    private var suggestionGeneration: UInt64 = 0

    public init(
        base: DashboardQuery,
        suggestions: SuggestionProvider? = nil,
        segmentList: SegmentListProvider? = nil,
        intervalPolicy: IntervalPolicy? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.base = base
        self.period = base.period
        self.periodDate = base.periodDate
        self.comparison = base.comparison
        self.matchDayOfWeek = base.matchDayOfWeek
        self.includeImported = base.includeImported
        self.interval = base.interval
        self.clauses = base.filters.clauses
        self.suggestions = suggestions
        self.segmentList = segmentList
        self.intervalPolicy = intervalPolicy
        self.clock = clock
        if segmentList != nil { segmentsState = .loading }
        refresh()
    }

    public var canSuggest: Bool { suggestions != nil }

    public var showsSegments: Bool {
        if case .unconfigured = segmentsState { return false }
        return true
    }

    /// Yesterday in the site timezone (periodDate-anchored `.day`).
    public func setYesterday(today: Date? = nil) {
        let now = today ?? clock()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = base.timeZone
        let start = calendar.startOfDay(for: now)
        period = .day
        periodDate = calendar.date(byAdding: .day, value: -1, to: start)
        refresh()
    }

    // MARK: - Mutations (each revalidates)

    public func setPeriod(_ period: Period, date: Date? = nil) {
        self.period = period
        self.periodDate = date
        refresh()
    }

    public func setComparison(_ comparison: Comparison) {
        self.comparison = comparison
        refresh()
    }

    /// Commits a clause only when the merged set stays valid. Rejections set
    /// `error` and leave existing clauses (and `effective`) untouched.
    @discardableResult
    public func addClause(_ clause: FilterClause) -> Bool {
        var candidate = clauses
        candidate.append(clause)
        do {
            try validate(clauses: locked.clauses + candidate, period: period, comparison: comparison)
        } catch let failure as QueryControlError {
            self.error = failure
            return false
        } catch {
            self.error = .filterInvalid(String(describing: error))
            return false
        }
        clauses = candidate
        if clause.dimension == .segment { appliedSegmentID = nil }
        refresh()
        return true
    }

    public func removeClause(at index: Int) {
        guard clauses.indices.contains(index) else { return }
        let removed = clauses.remove(at: index)
        if appliedSegmentClauses.contains(removed) {
            appliedSegmentClauses.removeAll { $0 == removed }
            if appliedSegmentClauses.isEmpty { appliedSegmentID = nil }
        }
        refresh()
    }

    public func clearUserFilters() {
        clauses.removeAll()
        appliedSegmentClauses.removeAll()
        appliedSegmentID = nil
        refresh()
    }

    /// Applies a saved segment: replaces any applied segment's clauses with
    /// the segment's stored filters (single-segment rule). Manual edits after
    /// applying detach the segment marker.
    @discardableResult
    public func applySegment(_ segment: SavedSegment) -> Bool {
        var candidate = clauses.filter { !appliedSegmentClauses.contains($0) }
        candidate += segment.filters.clauses
        do {
            try validate(clauses: locked.clauses + candidate, period: period, comparison: comparison)
        } catch let failure as QueryControlError {
            self.error = failure
            return false
        } catch {
            self.error = .filterInvalid(String(describing: error))
            return false
        }
        clauses = candidate
        appliedSegmentClauses = segment.filters.clauses
        appliedSegmentID = segment.id
        refresh()
        return true
    }

    public func clearSegment() {
        clauses.removeAll { appliedSegmentClauses.contains($0) }
        appliedSegmentClauses.removeAll()
        appliedSegmentID = nil
        refresh()
    }

    // MARK: - Suggestions and segments

    public func loadSegments() async {
        guard let segmentList, let query = effective else { return }
        segmentsState = .loading
        do {
            segmentsState = .loaded(try await segmentList(query))
        } catch {
            segmentsState = .failed(error as? ReportLoadError ?? ReportLoadError.wrap(error))
        }
    }

    /// Latest-wins suggestions; a superseded request never publishes.
    public func suggest(dimension: FilterDimension, propertyKey: String? = nil, input: String) async -> [Suggestion] {
        guard let suggestions, let query = effective else { return [] }
        suggestionGeneration &+= 1
        let generation = suggestionGeneration
        let wireName: String
        switch dimension {
        case .props:
            guard let propertyKey, !propertyKey.isEmpty else { return [] }
            wireName = propertyKey
        default:
            wireName = dimension.rawValue
        }
        let request = SuggestionRequest(query: query, filterName: wireName, input: input)
        do {
            let results = try await suggestions(request, clock())
            guard generation == suggestionGeneration else { return [] }
            return results
        } catch {
            return []
        }
    }

    // MARK: - Validation

    public func refresh() {
        if let policy = intervalPolicy {
            interval = policy.currentInterval(interval, for: period, periodDate: periodDate, timeZone: base.timeZone, today: clock())
        }
        do {
            effective = try build()
            error = nil
        } catch let failure as QueryControlError {
            effective = nil
            self.error = failure
        } catch {
            effective = nil
            self.error = .filterInvalid(String(describing: error))
        }
    }

    private func build() throws -> DashboardQuery {
        let merged = locked.clauses + clauses
        try validate(clauses: merged, period: period, comparison: comparison)
        return DashboardQuery(
            accountID: base.accountID,
            siteID: base.siteID,
            period: period,
            periodDate: periodDate,
            comparison: comparison,
            matchDayOfWeek: matchDayOfWeek,
            filters: FilterExpression(clauses: merged),
            includeImported: includeImported,
            interval: interval,
            selectedMetric: base.selectedMetric,
            timeZone: base.timeZone
        )
    }

    /// Mirrors the pinned dashboard: one goal filter, one single-valued
    /// segment filter, supported comparisons, ordered custom ranges, and the
    /// serializer's operator/type rules.
    private func validate(clauses: [FilterClause], period: Period, comparison: Comparison) throws {
        if clauses.contains(where: { $0.dimension == .goal }),
           clauses.filter({ $0.dimension == .goal }).count > 1 {
            throw QueryControlError.multipleGoalFilters
        }
        let segments = clauses.filter { $0.dimension == .segment }
        if segments.count > 1 {
            throw QueryControlError.multipleSegments
        }
        if let segment = segments.first,
           segment.values.count != 1 || !segment.values.allSatisfy({ if case .number = $0 { return true } else { return false } }) {
            throw QueryControlError.invalidSegmentValues
        }
        if comparison != .off, !comparison.isSupported(for: period) {
            throw QueryControlError.comparisonUnsupported(period: period.wireValue)
        }
        if case .custom(let from, let to) = period, from > to {
            throw QueryControlError.emptyCustomRange
        }
        if case .custom(let from, let to) = comparison, from > to {
            throw QueryControlError.emptyComparisonRange
        }
        do {
            _ = try FilterExpression(clauses: clauses).serialized()
        } catch let failure as FilterValidationError {
            throw QueryControlError.filterInvalid(String(describing: failure))
        }
    }
}
