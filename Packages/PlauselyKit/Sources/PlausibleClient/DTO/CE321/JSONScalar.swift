import AnalyticsCore
import Foundation

/// One JSON scalar preserving the server's int-vs-decimal-vs-string-vs-null
/// distinction. Counts must never pass through Double precision, so decimals
/// decode directly as `Decimal`.
public enum JSONScalar: Equatable, Sendable {
    case int(Int64)
    case decimal(Decimal)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let decimal = try? container.decode(Decimal.self) {
            self = .decimal(decimal)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.typeMismatch(
                JSONScalar.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "expected scalar")
            )
        }
    }

    /// Maps to a domain value. Strings where numbers are required are
    /// malformed payloads and throw; nulls become `.unavailable(.null)`.
    public func metricValue() throws -> MetricValue {
        switch self {
        case .int(let amount): return .count(amount)
        case .decimal(let amount): return .decimal(amount)
        case .null: return .unavailable(.null)
        case .string(let text):
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [], debugDescription: "numeric metric encoded as string: \(text)"
            ))
        }
    }
}

extension JSONScalar: Decodable {}
