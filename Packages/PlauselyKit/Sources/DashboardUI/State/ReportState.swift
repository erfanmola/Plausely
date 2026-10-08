import AnalyticsCore
import Foundation

/// Typed load failure. Cancellation never surfaces as this type; callers
/// swallow `CancellationError` without publishing an error banner.
public struct ReportLoadError: Error, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case network
        case authentication
        case server
        case unsupported
        case unknown
    }

    public let message: String
    public let kind: Kind

    public init(message: String, kind: Kind = .unknown) {
        self.message = message
        self.kind = kind
    }

    public static func wrap(_ error: Error) -> ReportLoadError {
        if let known = error as? ReportLoadError { return known }
        return ReportLoadError(message: String(describing: error), kind: .unknown)
    }
}

/// Shared lifecycle for every report view. Refresh keeps the previous envelope
/// visible as `.loading(stale:)`; a failed refresh keeps it as
/// `.failed(_, stale:)` so one bad request never erases good data.
public enum ReportLoadState<Value: Sendable>: Sendable {
    case idle
    case loading(stale: ReportEnvelope<Value>? = nil)
    case loaded(ReportEnvelope<Value>)
    case empty
    case failed(ReportLoadError, stale: ReportEnvelope<Value>? = nil)
    case unsupported(reason: String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Currently displayable envelope, including stale values shown during
    /// reload or after a failed refresh.
    public var displayable: ReportEnvelope<Value>? {
        switch self {
        case .idle, .empty, .unsupported: return nil
        case .loading(let stale): return stale
        case .loaded(let envelope): return envelope
        case .failed(_, let stale): return stale
        }
    }
}

/// Bounded actor-owned memory cache, keyed by canonical `QueryID`.
/// `QueryID` already embeds account/site/team/timezone/period/comparison/
/// filters/imports/metric/interval, so entries never leak across queries;
/// the stored account enables per-account eviction on logout/deletion.
public actor ReportCache<Value: Sendable> {
    private struct Entry: Sendable {
        let envelope: ReportEnvelope<Value>
        let account: AccountID
    }

    private var entries: [String: Entry] = [:]
    /// LRU order, oldest first.
    private var order: [String] = []
    public let maxEntries: Int

    public init(maxEntries: Int = 50) {
        self.maxEntries = max(1, maxEntries)
    }

    public func envelope(for queryID: QueryID) -> ReportEnvelope<Value>? {
        guard let entry = entries[queryID.rawValue] else { return nil }
        touch(queryID.rawValue)
        return entry.envelope
    }

    public func store(_ envelope: ReportEnvelope<Value>, account: AccountID) {
        let key = envelope.queryID.rawValue
        entries[key] = Entry(envelope: envelope, account: account)
        touch(key)
        while order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    public func removeAll(for account: AccountID) {
        let doomed = entries.filter { $0.value.account == account }.map(\.key)
        for key in doomed {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }

    public func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int { entries.count }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
