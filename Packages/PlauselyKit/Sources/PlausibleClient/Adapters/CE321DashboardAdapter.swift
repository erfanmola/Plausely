import AnalyticsCore
import Foundation

/// Dashboard API adapter for stock CE 3.2.1. Builds dashboard-faithful query
/// strings (period/date/from/to/filters/imported/comparison/compare range/
/// match-day-of-week, plus per-report extras), decodes strict DTOs, and maps
/// them to domain models with units and warnings preserved.
/// No fallback to any other API: unmapped content is a typed error.
public struct CE321DashboardAdapter: DashboardService, Sendable {
    private let coordinator: SessionCoordinator
    private let transport: HTTPTransport

    public init(coordinator: SessionCoordinator, transport: HTTPTransport) {
        self.coordinator = coordinator
        self.transport = transport
    }

    // MARK: - Query strings

    static func queryItems(for query: DashboardQuery, today: Date) throws -> [URLQueryItem] {
        var items = [URLQueryItem(name: "period", value: query.period.wireValue)]
        if let date = query.periodDate {
            items.append(URLQueryItem(name: "date", value: SiteDateRules.isoDay(date, in: query.timeZone)))
        }
        if case .custom = query.period {
            guard let range = SiteDateRules.range(for: query.period, periodDate: query.periodDate, timeZone: query.timeZone, today: today) else {
                throw DashboardQuery.ValidationError.unresolvedCustomRange
            }
            items.append(URLQueryItem(name: "from", value: SiteDateRules.isoDay(range.from, in: query.timeZone)))
            items.append(URLQueryItem(name: "to", value: SiteDateRules.isoDay(range.to, in: query.timeZone)))
        }
        items.append(URLQueryItem(name: "filters", value: try query.filters.serialized()))
        if query.includeImported {
            items.append(URLQueryItem(name: "with_imported", value: "true"))
        }
        if query.comparison != .off {
            items.append(URLQueryItem(name: "comparison", value: query.comparison.wireValue))
            if case .custom(let from, let to) = query.comparison {
                items.append(URLQueryItem(name: "compare_from", value: SiteDateRules.isoDay(from, in: query.timeZone)))
                items.append(URLQueryItem(name: "compare_to", value: SiteDateRules.isoDay(to, in: query.timeZone)))
            }
            items.append(URLQueryItem(name: "match_day_of_week", value: query.matchDayOfWeek ? "true" : "false"))
        }
        return items
    }

    // MARK: - Calls

    private func get(domain: String, endpoint: String, account: AccountID, base: URL, items: [URLQueryItem]) async throws -> Data {
        let builder = try RequestBuilder(baseURL: base)
        let headers = try await coordinator.headers(for: base, account: account)
        let request = builder.get(path: "api/stats/\(domain)/\(endpoint)", query: items, headers: headers)
        let (data, _) = try await transport.send(request)
        return data
    }

    public func overview(_ query: DashboardQuery, today: Date) async throws -> ReportEnvelope<Overview> {
        let credential = try await coordinator.restore(account: query.accountID)
        let items = try Self.queryItems(for: query, today: today)
        let data = try await get(domain: query.siteID.domain, endpoint: "top-stats", account: query.accountID, base: credential.baseURL, items: items)
        let dto = try JSONDecoder().decode(TopStatsDTO.self, from: data)
        let stats = try dto.topStats.map { stat -> TopStat in
            TopStat(
                metric: try Self.metricID(for: stat.graphMetric),
                name: stat.name,
                value: try stat.value.metricValue(),
                comparisonValue: try stat.comparisonValue?.metricValue(),
                change: stat.change
            )
        }
        let value = Overview(stats: stats, comparingFrom: dto.comparingFrom, comparingTo: dto.comparingTo)
        return ReportEnvelope(
            queryID: try QueryID.compute(for: query, today: today),
            value: value,
            retrievedAt: Date(),
            warnings: Self.warnings(from: dto.meta)
        )
    }

    public func series(_ query: DashboardQuery, today: Date) async throws -> ReportEnvelope<TimeSeries> {
        let credential = try await coordinator.restore(account: query.accountID)
        var items = try Self.queryItems(for: query, today: today)
        items.append(URLQueryItem(name: "interval", value: query.interval.rawValue))
        items.append(URLQueryItem(name: "metric", value: query.selectedMetric.rawValue))
        let data = try await get(domain: query.siteID.domain, endpoint: "main-graph", account: query.accountID, base: credential.baseURL, items: items)
        let dto = try JSONDecoder().decode(MainGraphDTO.self, from: data)
        let value = TimeSeries(
            metric: try Self.metricID(for: dto.metric),
            labels: dto.labels,
            plot: dto.plot.map { scalar in
                guard let scalar else { return nil }
                return try? scalar.metricValue()
            },
            comparisonLabels: dto.comparisonLabels,
            comparisonPlot: dto.comparisonPlot?.map { scalar in
                guard let scalar else { return nil }
                return try? scalar.metricValue()
            }
        )
        return ReportEnvelope(
            queryID: try QueryID.compute(for: query, today: today),
            value: value,
            retrievedAt: Date(),
            warnings: []
        )
    }

    public func breakdown(_ request: BreakdownRequest, today: Date) async throws -> ReportEnvelope<BreakdownPage> {
        let query = request.query
        let credential = try await coordinator.restore(account: query.accountID)
        var items = try Self.queryItems(for: query, today: today)
        items.append(URLQueryItem(name: "detailed", value: "true"))
        if let sort = request.sort {
            items.append(URLQueryItem(name: "order_by", value: try Self.orderBy(sort)))
        }
        items.append(URLQueryItem(name: "limit", value: "\(request.pagination.limit)"))
        items.append(URLQueryItem(name: "page", value: "\(request.pagination.page)"))
        if let search = request.search {
            items.append(URLQueryItem(name: "search", value: search))
        }
        let data = try await get(domain: query.siteID.domain, endpoint: request.kind.path(), account: query.accountID, base: credential.baseURL, items: items)
        let dto = try JSONDecoder().decode(BreakdownDTO.self, from: data)
        let rows = try dto.results.map { row -> BreakdownRow in
            var metrics: [MetricID: MetricValue] = [:]
            for (key, scalar) in row.metrics {
                if let metric = MetricID(rawValue: key) {
                    metrics[metric] = try scalar.metricValue()
                }
            }
            return BreakdownRow(name: row.name, code: row.code, metrics: metrics)
        }
        return ReportEnvelope(
            queryID: try QueryID.compute(for: query, today: today),
            value: BreakdownPage(rows: rows),
            retrievedAt: Date(),
            warnings: []
        )
    }

    public func suggestions(_ request: SuggestionRequest, today: Date) async throws -> [FilterSuggestion] {
        let query = request.query
        let credential = try await coordinator.restore(account: query.accountID)
        var items = try Self.queryItems(for: query, today: today)
        items.append(URLQueryItem(name: "q", value: request.input))
        let kind = ReportKind.suggestions(filter: request.filterName)
        let data = try await get(domain: query.siteID.domain, endpoint: kind.path(), account: query.accountID, base: credential.baseURL, items: items)
        return try JSONDecoder().decode([Suggestion].self, from: data).map {
            FilterSuggestion(label: $0.label, value: $0.value)
        }
    }

    public func currentVisitors(account: AccountID, site: SiteID) async throws -> CurrentVisitors {
        let credential = try await coordinator.restore(account: account)
        let builder = try RequestBuilder(baseURL: credential.baseURL)
        let headers = try await coordinator.headers(for: credential.baseURL, account: account)
        let request = builder.get(path: "api/stats/\(site.domain)/current-visitors", headers: headers)
        let (data, _) = try await transport.send(request)
        guard let count = try? JSONDecoder().decode(Int.self, from: data) else {
            throw ClientError.serverError(status: -1)
        }
        return CurrentVisitors(count: count)
    }

    // MARK: - Mapping

    static func metricID(for graphMetric: String) throws -> MetricID {
        if graphMetric == "views" { return .pageviews }
        guard let metric = MetricID(rawValue: graphMetric) else {
            throw ClientError.serverError(status: -1)
        }
        return metric
    }

    static func warnings(from meta: TopStatsDTO.Meta) -> [ReportWarning] {
        var warnings: [ReportWarning] = []
        if !meta.importsIncluded, let reason = meta.importsSkipReason {
            warnings.append(ReportWarning(code: "imports-skipped", message: reason))
        }
        return warnings
    }
    static func orderBy(_ sort: ReportSort) throws -> String {
        let entry: [Any]
        switch sort.key {
        case .metric(let metric): entry = [metric.rawValue, sort.direction.rawValue]
        case .dimension(let name): entry = [name, sort.direction.rawValue]
        }
        let data = try JSONSerialization.data(withJSONObject: [entry], options: [.withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
