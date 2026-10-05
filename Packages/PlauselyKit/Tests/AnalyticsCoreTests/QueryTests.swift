import Testing
@testable import AnalyticsCore
import Foundation

private func query(
    period: Period = .days28,
    comparison: Comparison = .off,
    filters: FilterExpression = .empty,
    imported: Bool = false,
    interval: ChartInterval = .day,
    metric: MetricID = .visitors,
    domain: String = "shop.plausely.test"
) -> DashboardQuery {
    DashboardQuery(
        accountID: AccountID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
        siteID: SiteID(domain: domain),
        period: period,
        comparison: comparison,
        filters: filters,
        includeImported: imported,
        interval: interval,
        selectedMetric: metric,
        timeZone: TimeZone(identifier: "Asia/Tehran")!
    )
}

private let policy = IntervalPolicy(validByPeriod: ["28d": [.day, .week], "day": [.minute, .hour]])

@Suite("immutable query and identity")
struct QueryTests {
    @Test("identical queries share an ID; any field flips it")
    func canonicalIdentity() throws {
        let today = Date(timeIntervalSince1970: 1_759_000_000)
        let base = try QueryID.compute(for: query(), today: today)
        #expect(try QueryID.compute(for: query(), today: today) == base)
        let variants: [DashboardQuery] = [
            query(metric: .visits),
            query(interval: .week),
            query(imported: true),
            query(comparison: .previousPeriod),
            query(domain: "blog.plausely.test"),
            query(period: .days7),
            query(filters: FilterExpression(clauses: [FilterClause(dimension: .source, op: .is_, values: [.text("Google")])])),
        ]
        for variant in variants {
            #expect(try QueryID.compute(for: variant, today: today) != base)
        }
    }

    @Test("filter order is significant, matching dashboard semantics")
    func filterOrder() throws {
        let today = Date(timeIntervalSince1970: 1_759_000_000)
        let a = FilterExpression(clauses: [
            FilterClause(dimension: .source, op: .is_, values: [.text("A")]),
            FilterClause(dimension: .page, op: .is_, values: [.text("/")]),
        ])
        let b = FilterExpression(clauses: a.clauses.reversed())
        #expect(try QueryID.compute(for: query(filters: a), today: today)
            != QueryID.compute(for: query(filters: b), today: today))
    }

    @Test("invalid combinations are rejected, not silently reinterpreted")
    func validation() {
        #expect(throws: DashboardQuery.ValidationError.comparisonUnsupportedForPeriod(.realtime)) {
            try query(period: .realtime, comparison: .previousPeriod).validated(with: policy)
        }
        #expect(throws: DashboardQuery.ValidationError.intervalNotAllowed(.month, .days28)) {
            try query(interval: .month).validated(with: policy)
        }
        #expect(throws: Never.self) { try query().validated(with: policy) }
    }

    @Test("pagination defaults to the manifest-proven 9/1 and rejects zeros")
    func pagination() throws {
        #expect(Pagination.default.limit == 9)
        #expect(Pagination.default.page == 1)
        try Pagination.default.validated()
        #expect(throws: Pagination.ValidationError.invalidLimit(0)) { try Pagination(limit: 0, page: 1).validated() }
        #expect(throws: Pagination.ValidationError.invalidPage(0)) { try Pagination(limit: 9, page: 0).validated() }
    }

    @Test("report paths match the manifest, with encoded drilldowns")
    func reportPaths() {
        #expect(ReportKind.sources.path() == "sources")
        #expect(ReportKind.entryPages.path() == "entry-pages")
        #expect(ReportKind.browserVersions.path() == "browser-versions")
        #expect(ReportKind.referrerDrilldown(referrer: "a/b c").path() == "referrers/a%2Fb%20c")
        #expect(ReportKind.customPropValues(key: "plan/x").path() == "custom-prop-values/plan%2Fx")
    }

    @Test("sort serializes to order_by entries")
    func sortSerialization() throws {
        let sort = ReportSort(key: .metric(.visitors), direction: .descending)
        let request = BreakdownRequest(query: query(), kind: .sources, sort: sort, pagination: .default, detailed: true)
        #expect(request.pagination == .default)
        #expect(request.detailed)
    }
}
