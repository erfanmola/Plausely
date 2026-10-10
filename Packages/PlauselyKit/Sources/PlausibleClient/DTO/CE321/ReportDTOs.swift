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
/// Realtime labels arrive as minute-offset integers (`-30…-1`); every
/// other period uses datetime strings. The adapter maps both to display
/// strings, so decoding never fails on the shape.
public struct MainGraphDTO: Decodable, Sendable {
    public let labels: [GraphLabel]
    public let plot: [JSONScalar?]
    public let metric: String
    public let comparisonLabels: [GraphLabel]?
    public let comparisonPlot: [JSONScalar?]?

    enum CodingKeys: String, CodingKey {
        case labels, plot, metric
        case comparisonLabels = "comparison_labels"
        case comparisonPlot = "comparison_plot"
    }
}

/// Graph bucket label: datetime strings on historical periods, integer
/// minute offsets on realtime.
public enum GraphLabel: Equatable, Sendable {
    case text(String)
    case minutesAgo(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let offset = try? container.decode(Int.self) {
            self = .minutesAgo(offset)
        } else {
            throw DecodingError.typeMismatch(
                GraphLabel.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "expected label string or minute offset")
            )
        }
    }
}

extension GraphLabel: Decodable {}

/// Breakdown response shared by all report families. Rows carry `name` plus
/// family-specific metric keys; identifiers (`code`, `browser`, `version`)
/// ride along as strings for drilldown context. With a comparison query the
/// server nests `comparison` (previous-period metric values, nulls allowed)
/// with `change` (percent deltas, null where uncomputable) per row; both
/// are absent without a comparison.
public struct BreakdownDTO: Decodable, Sendable {
    public struct Comparison: Decodable, Sendable {
        public let metrics: [String: JSONScalar]
        public let change: [String: Int?]

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
            init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            var metrics: [String: JSONScalar] = [:]
            var change: [String: Int?] = [:]
            for key in container.allKeys {
                switch key.stringValue {
                case "change":
                    // Percent deltas per metric, null where the server could
                    // not compute one. Decoded key-by-key so one malformed
                    // entry cannot wipe the rest.
                    if let nested = try? container.nestedContainer(keyedBy: Key.self, forKey: key) {
                        for changeKey in nested.allKeys {
                            if (try? nested.decodeNil(forKey: changeKey)) == true {
                                // Explicit server null (uncomputable delta):
                                // updateValue keeps the key with a nil delta
                                // instead of removing it.
                                change.updateValue(nil, forKey: changeKey.stringValue)
                            } else if let delta = try? nested.decode(Int.self, forKey: changeKey) {
                                change.updateValue(delta, forKey: changeKey.stringValue)
                            }
                        }
                    }
                default:
                    if let scalar = try? container.decode(JSONScalar.self, forKey: key) {
                        metrics[key.stringValue] = scalar
                    }
                }
            }
            self.metrics = metrics
            self.change = change
        }
    }

    public struct Row: Decodable, Sendable {
        public let name: String
        public let code: String?
        public let browser: String?
        public let version: String?
        public let flag: String?
        public let metrics: [String: JSONScalar]
        public let comparison: Comparison?

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
            var alpha3: String?
            var browser: String?
            var version: String?
            var flag: String?
            var metrics: [String: JSONScalar] = [:]
            var comparison: Comparison?
            for key in container.allKeys {
                switch key.stringValue {
                case "name":
                    name = try container.decode(String.self, forKey: key)
                case "code":
                    // Stable geo identifier, ISO-2 for filtering. City
                    // geoname IDs arrive as integers (pinned upstream
                    // cities_test.exs:40: `"code"=>588_409`), so integers
                    // stringify instead of failing the row.
                    if code == nil {
                        let text: String? = try? container.decodeIfPresent(String.self, forKey: key)
                        let number: Int? = try? container.decodeIfPresent(Int.self, forKey: key)
                        code = text ?? number.map { "\($0)" }
                    }
                case "alpha_3":
                    // ISO-3 fallback when no `code` is present.
                    if alpha3 == nil {
                        alpha3 = try? container.decodeIfPresent(String.self, forKey: key) ?? nil
                    }
                case "browser":
                    browser = try container.decodeIfPresent(String.self, forKey: key)
                case "version":
                    version = try container.decodeIfPresent(String.self, forKey: key)
                case "flag", "country_flag":
                    // Dashboard flag emoji; first one wins.
                    if flag == nil {
                        flag = try container.decodeIfPresent(String.self, forKey: key)
                    }
                case "comparison":
                    // Nested previous-period values; a malformed comparison
                    // fails loudly like any other required shape.
                    comparison = try container.decodeIfPresent(Comparison.self, forKey: key)
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
            self.code = code ?? alpha3
            self.browser = browser
            self.version = version
            self.flag = flag
            self.metrics = metrics
            self.comparison = comparison
        }
    }

    public let results: [Row]
    public let skipImportedReason: String?

    enum BreakdownKeys: String, CodingKey {
        case results
        case skipImportedReason = "skip_imported_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: BreakdownKeys.self)
        results = try container.decode([Row].self, forKey: .results)
        skipImportedReason = try container.decodeIfPresent(String.self, forKey: .skipImportedReason)
    }
}

/// Suggestion pairs for one filter dimension (decoded as a bare array).
public struct Suggestion: Decodable, Sendable {
    public let label: String
    public let value: String
}
