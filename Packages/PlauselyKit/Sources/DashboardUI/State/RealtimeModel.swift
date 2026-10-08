import AnalyticsCore
import Foundation

/// Live headcount lifecycle (LIVE-01/02): the site-wide 5-minute current
/// visitor count, polled on the dashboard's 30-second cadence while a site
/// is selected. Polling is foreground-driven by construction — the owning
/// view starts it on appear/query and stops it on disappear/query change,
/// so background/popped reports never poll. A failed poll keeps the last
/// count with an explicit error instead of zeroing it.
///
/// `onTick` lets window roots refresh realtime-period reports on the same
/// cadence; it stays nil for historical periods (badge polls regardless).
@MainActor
@Observable
public final class RealtimeModel {
    public typealias CountLoader = @Sendable (AccountID, SiteID) async throws -> Int

    /// Dashboard realtime cadence.
    public static let pollInterval: TimeInterval = 30

    public private(set) var count: Int?
    public private(set) var errorMessage: String?
    /// Window-root refresh for realtime periods. Plain (non-Sendable)
    /// closure on purpose: it captures MainActor report models and only
    /// ever runs on the main actor.
    public var onTick: (() async -> Void)?

    private let pollInterval: TimeInterval
    private var task: Task<Void, Never>?
    private var runningKey: String?

    public init(pollInterval: TimeInterval = RealtimeModel.pollInterval) {
        self.pollInterval = pollInterval
    }

    /// Starts (or restarts for a new account/site) the poll loop. Same
    /// identity while running is a no-op; a new identity resets the count
    /// so one site's headcount never flashes on another.
    public func start(account: AccountID, site: SiteID, loader: @escaping CountLoader) {
        let key = "\(account.rawValue.uuidString)/\(site.domain)"
        guard key != runningKey else { return }
        stop()
        runningKey = key
        count = nil
        errorMessage = nil
        task = Task {
            while !Task.isCancelled {
                do {
                    let fresh = try await loader(account, site)
                    guard !Task.isCancelled else { return }
                    count = fresh
                    errorMessage = nil
                    await onTick?()
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = (error as? ReportLoadError)?.message ?? "Live count unavailable"
                }
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        runningKey = nil
    }
}
