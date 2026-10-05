import Foundation

/// Dashboard filter dimensions (UI keys). Wire mapping follows the pinned
/// dashboard exactly (`util/filters.js`): `segment` stays bare,
/// `name`/`page`/`goal`/`hostname`/`props:*` take the `event:` prefix,
/// everything else takes `visit:`.
public enum FilterDimension: String, Hashable, Codable, Sendable, CaseIterable {
    case page
    case entryPage = "entry_page"
    case exitPage = "exit_page"
    case source
    case channel
    case referrer
    case country
    case region
    case city
    case screen
    case browser
    case browserVersion = "browser_version"
    case os
    case osVersion = "os_version"
    case utmMedium = "utm_medium"
    case utmSource = "utm_source"
    case utmCampaign = "utm_campaign"
    case utmTerm = "utm_term"
    case utmContent = "utm_content"
    case goal
    case props
    case hostname
    case segment
    case name

    /// Wire key for serialization. Props requires its key (`event:props:<key>`).
    func wireKey(propertyKey: String? = nil) throws -> String {
        switch self {
        case .segment:
            return "segment"
        case .page, .goal, .hostname, .name:
            return "event:\(rawValue)"
        case .props:
            guard let key = propertyKey, !key.isEmpty else {
                throw FilterValidationError.missingPropertyKey
            }
            return "event:props:\(key)"
        default:
            return "visit:\(rawValue)"
        }
    }

    /// Dimensions whose values are integer IDs on the wire.
    var usesIntegerValues: Bool {
        switch self {
        case .segment, .region, .city: return true
        default: return false
        }
    }
}

/// Filter operators. Wire names match the dashboard serializer.
public enum FilterOperator: String, Hashable, Codable, Sendable {
    case is_ = "is"
    case isNot = "is_not"
    case contains
    case containsNot = "contains_not"
    /// Goal exclusion. The dashboard expresses "goal is not X" as a
    /// `has_not_done` wrapper around an `is` clause; the model keeps the
    /// user-facing operator and the serializer performs the wrapping.
    case hasNotDone = "has_not_done"
}

/// A clause value. Text and integer IDs are distinct on the wire and must
/// never be confused (segment/region/city IDs are integers).
public enum FilterValue: Hashable, Sendable {
    case text(String)
    case number(Int)
}

/// One typed filter clause: dimension + operator + values.
/// Clauses within an expression are conjoined (AND); multiple values within
/// one clause are disjoined (OR), matching dashboard semantics.
public struct FilterClause: Hashable, Sendable {
    public let dimension: FilterDimension
    public let propertyKey: String?
    public let op: FilterOperator
    public let values: [FilterValue]

    public init(dimension: FilterDimension, propertyKey: String? = nil, op: FilterOperator, values: [FilterValue]) {
        self.dimension = dimension
        self.propertyKey = propertyKey
        self.op = op
        self.values = values
    }
}

public enum FilterValidationError: Error, Equatable {
    case emptyValues(FilterDimension)
    case missingPropertyKey
    case unsupportedOperator(FilterOperator, FilterDimension)
    case wrongValueType(FilterDimension)
    case goalExclusionOnlyForGoal
}

/// A complete filter set with validation and canonical serialization.
public struct FilterExpression: Hashable, Sendable {
    public let clauses: [FilterClause]
    public init(clauses: [FilterClause] = []) {
        self.clauses = clauses
    }

    public static let empty = FilterExpression()

    /// Validates against dashboard operator restrictions, then serializes to
    /// the exact wire form: JSON array of `[op, dimension, clauses]`.
    /// - `contains`/`contains_not` are rejected for screen/country/region/city.
    /// - `is_not` on goal serializes as the `has_not_done` wrapper.
    /// - `has_not_done` is accepted only for goal.
    /// - Segment/region/city values must be integers.
    public func serialized() throws -> String {
        let outer: [Any] = try clauses.map { try serialize(clause: $0) }
        // `.withoutEscapingSlashes` matches the dashboard's JSON.stringify
        // byte-for-byte (the server decodes both forms identically, but
        // canonical query identity needs one stable form).
        let data = try JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let string = String(data: data, encoding: .utf8) else {
            throw FilterValidationError.emptyValues(.page)
        }
        return string
    }

    private func serialize(clause: FilterClause) throws -> [Any] {
        guard !clause.values.isEmpty else {
            throw FilterValidationError.emptyValues(clause.dimension)
        }
        if clause.dimension == .props && (clause.propertyKey ?? "").isEmpty {
            throw FilterValidationError.missingPropertyKey
        }
        switch (clause.op, clause.dimension) {
        case (.contains, .screen), (.containsNot, .screen),
             (.contains, .country), (.containsNot, .country),
             (.contains, .region), (.containsNot, .region),
             (.contains, .city), (.containsNot, .city):
            throw FilterValidationError.unsupportedOperator(clause.op, clause.dimension)
        case (.hasNotDone, let dimension) where dimension != .goal:
            throw FilterValidationError.goalExclusionOnlyForGoal
        default:
            break
        }
        if clause.dimension.usesIntegerValues {
            for value in clause.values {
                guard case .number = value else {
                    throw FilterValidationError.wrongValueType(clause.dimension)
                }
            }
        }
        let wireDimension = try clause.dimension.wireKey(propertyKey: clause.propertyKey)
        let wireValues: [Any] = clause.values.map { value in
            switch value {
            case .text(let text): return text
            case .number(let number): return number
            }
        }
        if clause.op == .isNot, clause.dimension == .goal {
            return ["has_not_done", ["is", wireDimension, wireValues]]
        }
        return [clause.op.rawValue, wireDimension, wireValues]
    }
}
