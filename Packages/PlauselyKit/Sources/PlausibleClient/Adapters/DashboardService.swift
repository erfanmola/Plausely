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
