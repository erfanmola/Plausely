import Foundation

/// Stable account identity. Full domain/query contracts land in phase 02.
public struct AccountID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
