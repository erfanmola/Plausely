import Foundation

/// Dashboard breakdown families. Endpoint paths come from the verified
/// transport manifest (`/api/stats/:domain/` prefix); associated values carry
/// drilldown identity, never guessed pagination or sort.
public enum ReportKind: Hashable, Sendable {
    case sources
    case channels
    case searchTerms
    case utmMediums
    case utmSources
    case utmCampaigns
    case utmContents
    case utmTerms
    case referrerDrilldown(referrer: String)
    case pages
    case entryPages
    case exitPages
    case countries
    case regions
    case cities
    case browsers
    case browserVersions
    case operatingSystems
    case operatingSystemVersions
    case screenSizes
    case conversions
    case customPropValues(key: String)
    case suggestions(filter: String)

    /// Path segment appended to `/api/stats/:domain/`. Dynamic segments use
    /// strict percent-encoding (JS `encodeURIComponent` semantics: only
    /// unreserved characters pass through), matching dashboard behavior.
    public func path() -> String {
        switch self {
        case .sources: return "sources"
        case .channels: return "channels"
        case .searchTerms: return "referrers/Google"
        case .utmMediums: return "utm_mediums"
        case .utmSources: return "utm_sources"
        case .utmCampaigns: return "utm_campaigns"
        case .utmContents: return "utm_contents"
        case .utmTerms: return "utm_terms"
        case .referrerDrilldown(let referrer):
            return "referrers/\(ReportKind.encodeSegment(referrer))"
        case .pages: return "pages"
        case .entryPages: return "entry-pages"
        case .exitPages: return "exit-pages"
        case .countries: return "countries"
        case .regions: return "regions"
        case .cities: return "cities"
        case .browsers: return "browsers"
        case .browserVersions: return "browser-versions"
        case .operatingSystems: return "operating-systems"
        case .operatingSystemVersions: return "operating-system-versions"
        case .screenSizes: return "screen-sizes"
        case .conversions: return "conversions"
        case .customPropValues(let key):
            return "custom-prop-values/\(ReportKind.encodeSegment(key))"
        case .suggestions(let filter):
            return "suggestions/\(ReportKind.encodeSegment(filter))"
        }
    }

    static func encodeSegment(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

public enum SortDirection: String, Hashable, Codable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// Sort key: a metric or a dimension name. Serializes to the server's
/// `[["key","direction"]]` order_by entries.
public enum SortKey: Hashable, Sendable {
    case metric(MetricID)
    case dimension(String)

    var wireValue: String {
        switch self {
        case .metric(let metric): return metric.rawValue
        case .dimension(let name): return name
        }
    }
}

public struct ReportSort: Hashable, Sendable {
    public let key: SortKey
    public let direction: SortDirection
    public init(key: SortKey, direction: SortDirection) {
        self.key = key
        self.direction = direction
    }

    func serialized() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [[key.wireValue, direction.rawValue]],
            options: [.withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

/// Server pagination. Defaults are the manifest-proven `limit=9, page=1`
/// (1-based). The dashboard path has no max cap; export uses its own caps.
public struct Pagination: Hashable, Sendable {
    public static let `default` = Pagination(limit: 9, page: 1)
    public let limit: Int
    public let page: Int

    public init(limit: Int, page: Int) {
        self.limit = limit
        self.page = page
    }

    public enum ValidationError: Error, Equatable {
        case invalidLimit(Int)
        case invalidPage(Int)
    }

    public func validated() throws {
        guard limit >= 1 else { throw ValidationError.invalidLimit(limit) }
        guard page >= 1 else { throw ValidationError.invalidPage(page) }
    }
}

/// One breakdown request: immutable query plus report context.
/// `search` applies only where the server accepts it (Google drilldown);
/// elsewhere search is expressed as a filter clause (phase-00 finding).
public struct BreakdownRequest: Hashable, Sendable {
    public let query: DashboardQuery
    public let kind: ReportKind
    public let sort: ReportSort?
    public let search: String?
    public let pagination: Pagination
    public let detailed: Bool

    public init(query: DashboardQuery, kind: ReportKind, sort: ReportSort? = nil, search: String? = nil, pagination: Pagination = .default, detailed: Bool = false) {
        self.query = query
        self.kind = kind
        self.sort = sort
        self.search = search
        self.pagination = pagination
        self.detailed = detailed
    }
}

/// Suggestion lookup for one filter dimension. `q` is required server-side.
public struct SuggestionRequest: Hashable, Sendable {
    public let query: DashboardQuery
    public let filterName: String
    public let input: String
    public init(query: DashboardQuery, filterName: String, input: String) {
        self.query = query
        self.filterName = filterName
        self.input = input
    }
}
