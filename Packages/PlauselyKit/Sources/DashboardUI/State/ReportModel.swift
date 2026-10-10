import AnalyticsCore
import Foundation
import Observation

/// One report's lifecycle: query generation, cancel/publish identity,
/// stale retention, dedup, and cache-first loads.
///
/// Rules:
/// - Every `load` computes the canonical `QueryID` and bumps `generation`;
///   the previous task is cancelled. A result publishes only when both its
///   `QueryID` and `generation` still match, so a delayed A can never
///   overwrite a newer B even when cancellation was ignored.
/// - `CancellationError` never becomes an error banner.
/// - A concurrent `load`/`refresh` for the already-loading `QueryID` is
///   deduplicated onto the in-flight fetch.
/// - `load` serves a cache hit without networking; `refresh` always
///   revalidates while keeping the old value visible as stale.
@MainActor
@Observable
public final class ReportModel<Value: Sendable> {
    public typealias Loader = @Sendable (DashboardQuery, Date) async throws -> ReportEnvelope<Value>

    public private(set) var query: DashboardQuery?
    public private(set) var queryID: QueryID?
    public private(set) var state: ReportLoadState<Value> = .idle

    private let loader: Loader
    private let isEmpty: @Sendable (Value) -> Bool
    private let cache: ReportCache<Value>?
    private let clock: @Sendable () -> Date

    private var generation: UInt64 = 0
    private var loadingID: QueryID?
    private var loadTask: Task<Void, Never>?

    public init(
        loader: @escaping Loader,
        isEmpty: @escaping @Sendable (Value) -> Bool = { _ in false },
        cache: ReportCache<Value>? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.isEmpty = isEmpty
        self.cache = cache
        self.clock = clock
    }

    /// Cache-first load. Serves a matching cache entry with no fetch.
    public func load(query: DashboardQuery, today: Date? = nil) async {
        let now = today ?? clock()
        let id: QueryID
        do {
            id = try QueryID.compute(for: query, today: now)
        } catch {
            publishFailed(ReportLoadError.wrap(error), stale: state.displayable)
            return
        }
        if state.isLoading, loadingID == id { return } // dedup
        if let cache, let hit = await cache.envelope(for: id) {
            queryDidSettle(query: query, id: id)
            publishEnvelope(hit)
            return
        }
        await fetch(query: query, id: id, today: now)
    }

    /// Forced revalidation; keeps the current value visible as stale.
    public func refresh(today: Date? = nil) async {
        guard let current = query else { return }
        let now = today ?? clock()
        let id: QueryID
        do {
            id = try QueryID.compute(for: current, today: now)
        } catch {
            publishFailed(ReportLoadError.wrap(error), stale: state.displayable)
            return
        }
        if state.isLoading, loadingID == id { return } // dedup manual refresh
        await fetch(query: current, id: id, today: now)
    }

    public func retry(today: Date? = nil) async {
        await refresh(today: today)
    }

    public func cancel() {
        loadTask?.cancel()
        loadTask = nil
        // Cancellation alone does not clear the visible value; the next
        // fetch bumps generation and supersedes anything still running.
        if state.isLoading {
            loadingID = nil
            if let stale = state.displayable {
                state = .loaded(stale)
            } else {
                state = .idle
            }
        }
    }

    public func publishUnsupported(reason: String) {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        loadingID = nil
        state = .unsupported(reason: reason)
    }

    // MARK: - Internals

    private func fetch(query: DashboardQuery, id: QueryID, today: Date) async {
        loadTask?.cancel()
        generation &+= 1
        let myGeneration = generation
        let stale = state.displayable
        self.query = query
        self.queryID = id
        loadingID = id
        state = .loading(stale: stale)
        let loader = loader
        let cache = cache
        loadTask = Task {
            do {
                let envelope = try await loader(query, today)
                await cache?.store(envelope, account: query.accountID)
                await self.publishFetched(envelope, id: id, generation: myGeneration)
            } catch is CancellationError {
                // Not an error banner; leave state for the superseding fetch.
            } catch {
                await self.publishFetchFailed(ReportLoadError.wrap(error), id: id, generation: myGeneration)
            }
        }
        await loadTask?.value
    }

    private func publishFetched(_ envelope: ReportEnvelope<Value>, id: QueryID, generation: UInt64) {
        guard generation == self.generation, queryID == id else { return } // late A discarded
        loadingID = nil
        publishEnvelope(envelope)
    }

    private func publishFetchFailed(_ error: ReportLoadError, id: QueryID, generation: UInt64) {
        guard generation == self.generation, queryID == id else { return }
        loadingID = nil
        publishFailed(error, stale: state.displayable)
    }

    private func publishEnvelope(_ envelope: ReportEnvelope<Value>) {
        state = isEmpty(envelope.value) ? .empty : .loaded(envelope)
    }

    private func publishFailed(_ error: ReportLoadError, stale: ReportEnvelope<Value>?) {
        if error.kind == .unsupported {
            state = .unsupported(reason: error.message)
        } else {
            state = .failed(error, stale: stale)
        }
    }

    private func queryDidSettle(query: DashboardQuery, id: QueryID) {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        self.query = query
        self.queryID = id
        loadingID = nil
    }
}

/// Vertical-slice coordinator for 04.1: two independent report lifecycles
/// sharing one query. A failure in one never erases the other's value;
/// each keeps its own generation/identity, cache, and stale state.
@MainActor
@Observable
public final class DashboardModel {
    public let overview: ReportModel<Overview>
    public let series: ReportModel<TimeSeries>
    /// Best-effort previous-period overview behind headline deltas. Loads
    /// only when the main query carries no comparison of its own; shares
    /// the overview cache (trend QueryIDs differ by comparison).
    public let trend: ReportModel<Overview>
    private let overviewCache: ReportCache<Overview>?
    private let seriesCache: ReportCache<TimeSeries>?

    public init(
        overviewLoader: @escaping ReportModel<Overview>.Loader,
        seriesLoader: @escaping ReportModel<TimeSeries>.Loader,
        overviewCache: ReportCache<Overview>? = nil,
        seriesCache: ReportCache<TimeSeries>? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.overviewCache = overviewCache
        self.seriesCache = seriesCache
        overview = ReportModel(
            loader: overviewLoader,
            isEmpty: { $0.stats.isEmpty },
            cache: overviewCache,
            clock: clock
        )
        series = ReportModel(
            loader: seriesLoader,
            isEmpty: { $0.plot.isEmpty || $0.plot.allSatisfy { $0 == nil } },
            cache: seriesCache,
            clock: clock
        )
        trend = ReportModel(
            loader: overviewLoader,
            isEmpty: { $0.stats.isEmpty },
            cache: overviewCache,
            clock: clock
        )
    }

    /// Loads both reports for the query. Failures are contained per report.
    public func load(query: DashboardQuery, today: Date? = nil) async {
        async let first: () = overview.load(query: query, today: today)
        async let second: () = series.load(query: query, today: today)
        await first
        await second
    }

    public func refresh(today: Date? = nil) async {
        async let first: () = overview.refresh(today: today)
        async let second: () = series.refresh(today: today)
        await first
        await second
    }

    public func cancel() {
        overview.cancel()
        series.cancel()
        trend.cancel()
    }

    public func clearCache(for account: AccountID) async {
        await overviewCache?.removeAll(for: account)
        await seriesCache?.removeAll(for: account)
    }
}
