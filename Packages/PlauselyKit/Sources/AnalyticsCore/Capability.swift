import Foundation

/// Availability of one capability for one account/site/version.
/// Only verified server absence maps to `unsupported`; everything else keeps
/// its distinct state so UI never disguises a gap as a fact.
public enum CapabilityStatus: Hashable, Codable, Sendable {
    /// Proven working against the pinned version.
    case available
    /// Stock baseline CE lacks this feature (source + running-build proof).
    case editionAbsent
    /// Needs server-side setup (goals, props, imports, integrations).
    case configurationMissing(reason: String)
    /// Authenticated role may not use it.
    case roleDenied
    /// Not yet probed on this deployment.
    case unverified
    /// Client has not implemented it yet (never shown as unsupported).
    case appMissing
    /// Transient failure; retry may succeed.
    case temporaryFailure(reason: String)
}

/// One scoped capability entry with its evidence.
public struct Capability: Hashable, Sendable {
    public let id: String
    public let status: CapabilityStatus
    public let evidence: String

    public init(id: String, status: CapabilityStatus, evidence: String) {
        self.id = id
        self.status = status
        self.evidence = evidence
    }

    /// Whether the feature may be attempted. Only `available` proceeds;
    /// every other state maps to its own honest UI (empty, error, setup
    /// prompt, or hidden pending verification).
    public var mayAttempt: Bool {
        if case .available = status { return true }
        return false
    }
}
