import Foundation

/// Opaque identity of one complete report request. Phase 02.4 defines how the
/// canonical identity is computed; this carrier lets envelopes reference it.
public struct QueryID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One decoded report value with retrieval context. Presentation reads only
/// `value`; nothing here performs networking or caching.
public struct ReportEnvelope<Value: Sendable>: Sendable {
    public let queryID: QueryID
    public let value: Value
    public let retrievedAt: Date
    public let warnings: [ReportWarning]

    public init(queryID: QueryID, value: Value, retrievedAt: Date, warnings: [ReportWarning] = []) {
        self.queryID = queryID
        self.value = value
        self.retrievedAt = retrievedAt
        self.warnings = warnings
    }
}

/// Non-fatal server notices (imported-data mix, legacy metrics, sampling).
public struct ReportWarning: Hashable, Codable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// One headline number from `top-stats`, with optional comparison context.
/// `change` is the server's percent change; never computed client-side.
public struct TopStat: Equatable, Sendable {
    public let metric: MetricID
    public let name: String
    public let value: MetricValue
    public let comparisonValue: MetricValue?
    public let change: Int?

    public init(metric: MetricID, name: String, value: MetricValue, comparisonValue: MetricValue? = nil, change: Int? = nil) {
        self.metric = metric
        self.name = name
        self.value = value
        self.comparisonValue = comparisonValue
        self.change = change
    }
}

/// The full `top-stats` response: headline numbers in dashboard order.
public struct Overview: Equatable, Sendable {
    public let stats: [TopStat]
    public let comparingFrom: String?
    public let comparingTo: String?

    public init(stats: [TopStat], comparingFrom: String? = nil, comparingTo: String? = nil) {
        self.stats = stats
        self.comparingFrom = comparingFrom
        self.comparingTo = comparingTo
    }
}

/// A `main-graph` series. `plot` is bucket-aligned with `labels`; a nil
/// bucket is a genuine gap (no data), never a fabricated zero or future value.
public struct TimeSeries: Equatable, Sendable {
    public let metric: MetricID
    public let labels: [String]
    public let plot: [MetricValue?]
    public let comparisonLabels: [String]?
    public let comparisonPlot: [MetricValue?]?

    public init(metric: MetricID, labels: [String], plot: [MetricValue?], comparisonLabels: [String]? = nil, comparisonPlot: [MetricValue?]? = nil) {
        self.metric = metric
        self.labels = labels
        self.plot = plot
        self.comparisonLabels = comparisonLabels
        self.comparisonPlot = comparisonPlot
    }
}

/// One breakdown row. Metrics vary by report and `detailed` flag; absent
/// columns are absent keys, never zero-filled. `code` carries stable
/// identifiers (country/region codes) where the server provides them.
/// `comparison` carries the previous-period values the server returns only
/// when the query has a comparison (upstream `sources_test.exs`
/// "compares sources with previous period": nested `comparison` with
/// `change` percents per metric); nil means the server sent none.
/// `change` is the server's percent change per metric (nil value = the
/// server could not compute it, e.g. null comparison duration); the client
/// never computes it. Hashable so rows can travel through navigation
/// values (05.2).
public struct BreakdownRow: Hashable, Sendable {
    public let name: String
    public let code: String?
    /// Dashboard flag emoji for geo rows (nil elsewhere). Decorative:
    /// views hide it from VoiceOver; the name carries the meaning.
    public let flag: String?
    public let metrics: [MetricID: MetricValue]
    public let comparison: [MetricID: MetricValue]?
    public let change: [MetricID: Int?]

    public init(
        name: String,
        code: String? = nil,
        flag: String? = nil,
        metrics: [MetricID: MetricValue],
        comparison: [MetricID: MetricValue]? = nil,
        change: [MetricID: Int?] = [:]
    ) {
        self.name = name
        self.code = code
        self.flag = flag
        self.metrics = metrics
        self.comparison = comparison
        self.change = change
    }
}

/// One page of a breakdown report, in server order.
public struct BreakdownPage: Equatable, Sendable {
    public let rows: [BreakdownRow]
    public init(rows: [BreakdownRow]) {
        self.rows = rows
    }
}
