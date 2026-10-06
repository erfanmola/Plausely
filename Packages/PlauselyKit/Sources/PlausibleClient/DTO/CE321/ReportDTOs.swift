import AnalyticsCore
import Foundation

/// `top-stats` response. Unknown additive fields are ignored; missing
/// required keys throw. Comparison fields appear only with a comparison.
public struct TopStatsDTO: Decodable, Sendable {
    public struct Stat: Decodable, Sendable {
        public let name: String
        public let value: JSONScalar
        public let graphMetric: String
        public let change: Int?
        public let comparisonValue: JSONScalar?

        enum CodingKeys: String, CodingKey {
            case name, value
            case graphMetric = "graph_metric"
            case change
            case comparisonValue = "comparison_value"
        }
    }

    public struct Meta: Decodable, Sendable {
        public let importsIncluded: Bool
        public let importsSkipReason: String?

        enum CodingKeys: String, CodingKey {
            case importsIncluded = "imports_included"
            case importsSkipReason = "imports_skip_reason"
        }
    }

    public let meta: Meta
    public let from: String?
    public let to: String?
    public let interval: String?
    public let samplePercent: JSONScalar?
    public let graphableMetrics: [String]
    public let topStats: [Stat]
    public let comparingFrom: String?
    public let comparingTo: String?

    enum CodingKeys: String, CodingKey {
        case meta, from, to, interval
        case samplePercent = "sample_percent"
        case graphableMetrics = "graphable_metrics"
        case topStats = "top_stats"
        case comparingFrom = "comparing_from"
        case comparingTo = "comparing_to"
    }
}

/// `main-graph` response. `plot` preserves null buckets positionally.
public struct MainGraphDTO: Decodable, Sendable {
    public let labels: [String]
    public let plot: [JSONScalar?]
    public let metric: String
    public let comparisonLabels: [String]?
    public let comparisonPlot: [JSONScalar?]?

    enum CodingKeys: String, CodingKey {
        case labels, plot, metric
        case comparisonLabels = "comparison_labels"
        case comparisonPlot = "comparison_plot"
    }
}

/// Breakdown response shared by all report families. Rows carry `name` plus
/// family-specific metric keys; identifiers (`code`, `browser`, `version`)
/// ride along as strings for drilldown context.
public struct BreakdownDTO: Decodable, Sendable {
    public struct Row: Decodable, Sendable {
        public let name: String
        public let code: String?
        public let browser: String?
        public let version: String?
        public let metrics: [String: JSONScalar]

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
            init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            var name: String?
            var code: String?
            var browser: String?
            var version: String?
            var metrics: [String: JSONScalar] = [:]
            for key in container.allKeys {
                switch key.stringValue {
                case "name":
                    name = try container.decode(String.self, forKey: key)
                case "code", "alpha_3":
                    // Stable geo identifier; first one wins.
                    if code == nil {
                        code = try container.decodeIfPresent(String.self, forKey: key)
                    }
                case "browser":
                    browser = try container.decodeIfPresent(String.self, forKey: key)
                case "version":
                    version = try container.decodeIfPresent(String.self, forKey: key)
                default:
                    // Numeric metric columns; unexpected strings are kept as
                    // scalars so the adapter rejects them loudly.
                    if let scalar = try? container.decode(JSONScalar.self, forKey: key) {
                        metrics[key.stringValue] = scalar
                    }
                }
            }
            guard let name else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "breakdown row without name"
                ))
            }
            self.name = name
            self.code = code
            self.browser = browser
            self.version = version
            self.metrics = metrics
        }
    }

    public let results: [Row]
}

/// Suggestion pairs for one filter dimension (decoded as a bare array).
public struct Suggestion: Decodable, Sendable {
    public let label: String
    public let value: String
}
