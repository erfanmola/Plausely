import AnalyticsCore
import Foundation

/// Read-only analytics service. v1 covers overview, series, breakdowns,
/// suggestions, and realtime headcount against the pinned CE dashboard API.
/// Goal-filtered variants ride the same methods via filters; search-terms
/// (GSC) and exports land with their phases and extend this protocol.
public protocol DashboardService: Sendable {
    func overview(_ query: DashboardQuery, today: Date) async throws -> ReportEnvelope<Overview>
    func series(_ query: DashboardQuery, today: Date) async throws -> ReportEnvelope<TimeSeries>
    func breakdown(_ request: BreakdownRequest, today: Date) async throws -> ReportEnvelope<BreakdownPage>
    func suggestions(_ request: SuggestionRequest, today: Date) async throws -> [FilterSuggestion]
    func currentVisitors(account: AccountID, site: SiteID) async throws -> CurrentVisitors
    /// Server-rendered ZIP of the current query (EXPORT-01). The server caps
    /// most reports at 300 rows (pages/exit at 100); caps are server-side
    /// and reported honestly, never padded client-side.
    func export(_ query: DashboardQuery, today: Date) async throws -> DashboardExport
}

public struct FilterSuggestion: Hashable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct CurrentVisitors: Hashable, Sendable {
    public let count: Int
    public init(count: Int) {
        self.count = count
    }
}

/// One server-rendered dashboard export: the ZIP bytes plus the server's
/// filename (which carries the site and date range).
public struct DashboardExport: Hashable, Sendable {
    public let filename: String
    public let data: Data
    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
    }
}
