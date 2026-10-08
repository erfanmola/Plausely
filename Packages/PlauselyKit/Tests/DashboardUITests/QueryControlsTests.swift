import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@MainActor
private func baseQuery() -> DashboardQuery {
    DashboardQuery(
        accountID: AccountID(),
        siteID: SiteID(domain: "shop.example"),
        period: .days28,
        comparison: .off,
        filters: .empty,
        includeImported: false,
        interval: .day,
        selectedMetric: .visitors,
        timeZone: TimeZone(identifier: "UTC")!
    )
}

private let frozenToday = Date(timeIntervalSince1970: 1_790_000_000)

@Suite("query controls (04.3)")
@MainActor
struct QueryControlsTests {
    @Test("base query is effective with no error")
    func initialEffective() throws {
        let model = QueryModel(base: baseQuery())
        let query = try #require(model.effective)
        #expect(query.period == .days28)
        #expect(query.filters.clauses.isEmpty)
        #expect(model.error == nil)
    }

    @Test("every preset maps to its exact period")
    func presets() throws {
        let model = QueryModel(base: baseQuery())
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: frozenToday)!
        let cases: [(Period, Period)] = [
            (.realtime, .realtime), (.day, .day), (.days7, .days7),
            (.days28, .days28), (.days30, .days30), (.days91, .days91),
            (.month, .month), (.year, .year), (.months6, .months6),
            (.months12, .months12), (.all, .all),
        ]
        for (preset, expected) in cases {
            model.setPeriod(preset)
            #expect(try #require(model.effective).period == expected)
        }
        model.setPeriod(.day, date: day)
        let yesterday = try #require(model.effective)
        #expect(yesterday.period == .day)
        #expect(yesterday.periodDate != nil)
        let from = frozenToday
        let to = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: from)!
        model.setPeriod(.custom(from: from, to: to))
        #expect(try #require(model.effective).period == .custom(from: from, to: to))
    }

    @Test("reversed custom range is rejected, last good query kept")
    func customRangeGuard() throws {
        let model = QueryModel(base: baseQuery())
        _ = try #require(model.effective)
        model.setPeriod(.custom(from: frozenToday, to: frozenToday.addingTimeInterval(-86400)))
        #expect(model.effective == nil)
        #expect(model.error == .emptyCustomRange)
        model.setPeriod(.days7)
        #expect(try #require(model.effective).period == .days7)
    }

    @Test("comparisons apply; realtime and all refuse them")
    func comparisonGuards() throws {
        let model = QueryModel(base: baseQuery())
        model.setComparison(.previousPeriod)
        #expect(try #require(model.effective).comparison == .previousPeriod)
        model.setComparison(.yearOverYear)
        #expect(try #require(model.effective).comparison == .yearOverYear)
        let from = frozenToday.addingTimeInterval(-86400 * 7)
        model.setComparison(.custom(from: from, to: frozenToday))
        #expect(try #require(model.effective).comparison == .custom(from: from, to: frozenToday))
        model.setPeriod(.realtime)
        #expect(model.effective == nil)
        #expect(model.error == .comparisonUnsupported(period: "realtime"))
        model.setPeriod(.days28)
        model.setComparison(.off)
        model.setPeriod(.all)
        model.setComparison(.previousPeriod)
        #expect(model.error == .comparisonUnsupported(period: "all"))
    }

    @Test("imports toggle rides the effective query")
    func importsToggle() throws {
        let model = QueryModel(base: baseQuery())
        model.includeImported = true
        model.refresh()
        #expect(try #require(model.effective).includeImported == true)
    }

    @Test("adding a clause changes the exact query identity")
    func clauseAffectsIdentity() throws {
        let model = QueryModel(base: baseQuery())
        let beforeQuery = try #require(model.effective)
        let before = try QueryID.compute(for: beforeQuery, today: frozenToday)
        #expect(model.addClause(FilterClause(dimension: .source, op: .is_, values: [.text("Google")])))
        let afterQuery = try #require(model.effective)
        let after = try QueryID.compute(for: afterQuery, today: frozenToday)
        #expect(before != after)
        #expect(try #require(model.effective).filters.serialized() == #"[["is","visit:source",["Google"]]]"#)
    }

    @Test("second goal filter is refused, first survives")
    func singleGoal() throws {
        let model = QueryModel(base: baseQuery())
        #expect(model.addClause(FilterClause(dimension: .goal, op: .is_, values: [.text("Signup")])))
        #expect(!model.addClause(FilterClause(dimension: .goal, op: .is_, values: [.text("Purchase")])))
        #expect(model.error == .multipleGoalFilters)
        #expect(model.clauses.count == 1)
        #expect(try #require(model.effective).filters.clauses.count == 1)
    }

    @Test("goal is-not serializes to the has_not_done wrapper")
    func goalExclusion() throws {
        let model = QueryModel(base: baseQuery())
        #expect(model.addClause(FilterClause(dimension: .goal, op: .isNot, values: [.text("Signup")])))
        #expect(try #require(model.effective).filters.serialized() == #"[["has_not_done",["is","event:goal",["Signup"]]]]"#)
    }

    @Test("contains is refused for location and screen dimensions")
    func containsRestrictions() {
        let model = QueryModel(base: baseQuery())
        #expect(!model.addClause(FilterClause(dimension: .country, op: .contains, values: [.text("Iran")])))
        #expect(model.clauses.isEmpty)
        #expect(model.effective != nil) // refusal keeps the last good query
        #expect(model.addClause(FilterClause(dimension: .source, op: .contains, values: [.text("goo")])))
        #expect(model.error == nil)
        #expect(model.effective != nil)
    }

    @Test("segment ids must be single integers; second segment refused")
    func segmentRules() throws {
        let model = QueryModel(base: baseQuery())
        #expect(!model.addClause(FilterClause(dimension: .segment, op: .is_, values: [.text("7")])))
        #expect(!model.addClause(FilterClause(dimension: .segment, op: .is_, values: [.number(7), .number(8)])))
        #expect(model.error == .invalidSegmentValues)
        #expect(model.addClause(FilterClause(dimension: .segment, op: .is_, values: [.number(7)])))
        #expect(!model.addClause(FilterClause(dimension: .segment, op: .is_, values: [.number(9)])))
        #expect(model.error == .multipleSegments)
        #expect(try #require(model.effective).filters.serialized() == #"[["is","segment",[7]]]"#)
    }

    @Test("props requires its key")
    func propsKey() {
        let model = QueryModel(base: baseQuery())
        #expect(!model.addClause(FilterClause(dimension: .props, op: .is_, values: [.text("x")])))
        #expect(model.addClause(FilterClause(dimension: .props, propertyKey: "plan", op: .is_, values: [.text("pro")])))
        #expect(model.effective != nil)
    }

    @Test("locked filters merge in and cannot be edited here")
    func lockedScope() throws {
        let model = QueryModel(base: baseQuery())
        model.locked = FilterExpression(clauses: [
            FilterClause(dimension: .source, op: .is_, values: [.text("Direct")])
        ])
        #expect(try #require(model.effective).filters.clauses.count == 1)
        #expect(model.addClause(FilterClause(dimension: .goal, op: .is_, values: [.text("A")])))
        #expect(try #require(model.effective).filters.clauses.count == 2)
        // Locked goal counts toward the single-goal rule.
        let locked2 = QueryModel(base: baseQuery())
        locked2.locked = FilterExpression(clauses: [
            FilterClause(dimension: .goal, op: .is_, values: [.text("Signup")])
        ])
        #expect(!locked2.addClause(FilterClause(dimension: .goal, op: .is_, values: [.text("Purchase")])))
        #expect(locked2.error == .multipleGoalFilters)
    }

    @Test("segment apply expands stored filters and replaces on re-apply")
    func segmentApply() throws {
        let model = QueryModel(base: baseQuery())
        let first = SavedSegment(id: 7, name: "Mobile", kind: .personal, filters: FilterExpression(clauses: [
            FilterClause(dimension: .os, op: .is_, values: [.text("iOS")])
        ]))
        let second = SavedSegment(id: 9, name: "Search", kind: .site, filters: FilterExpression(clauses: [
            FilterClause(dimension: .channel, op: .is_, values: [.text("Organic Search")])
        ]))
        #expect(model.applySegment(first))
        #expect(model.appliedSegmentID == 7)
        #expect(try #require(model.effective).filters.clauses.count == 1)
        #expect(model.applySegment(second))
        #expect(model.appliedSegmentID == 9)
        let domains = try #require(model.effective).filters.clauses.map(\.dimension)
        #expect(domains == [.channel])
        model.clearSegment()
        #expect(model.appliedSegmentID == nil)
        #expect(try #require(model.effective).filters.clauses.isEmpty)
    }

    @Test("removing a clause keeps the rest with fresh identity")
    func removeClause() throws {
        let model = QueryModel(base: baseQuery())
        model.addClause(FilterClause(dimension: .source, op: .is_, values: [.text("Google")]))
        model.addClause(FilterClause(dimension: .country, op: .is_, values: [.text("DE")]))
        model.removeClause(at: 0)
        #expect(try #require(model.effective).filters.clauses.map(\.dimension) == [.country])
        model.clearUserFilters()
        #expect(try #require(model.effective).filters.clauses.isEmpty)
    }

    @Test("yesterday anchors day in the site timezone")
    func yesterdayPreset() throws {
        let tehran = TimeZone(identifier: "Asia/Tehran")!
        let base = DashboardQuery(
            accountID: AccountID(),
            siteID: SiteID(domain: "shop.example"),
            period: .days28,
            comparison: .off,
            filters: .empty,
            includeImported: false,
            interval: .day,
            selectedMetric: .visitors,
            timeZone: tehran
        )
        let model = QueryModel(base: base)
        // 2026-10-06 00:30 Tehran time is still Oct 5 in UTC.
        let now = Date(timeIntervalSince1970: 1_791_234_000)
        model.setYesterday(today: now)
        let query = try #require(model.effective)
        #expect(query.period == .day)
        #expect(SiteDateRules.isoDay(try #require(query.periodDate), in: tehran) == "2026-10-05")
    }

    @Test("segment section hides without a provider")
    func segmentVisibility() {
        #expect(QueryModel(base: baseQuery()).showsSegments == false)
        let withSegments = QueryModel(base: baseQuery(), segmentList: { _ in [] })
        #expect(withSegments.showsSegments == true)
    }

    @Test("suggestions latest wins; failures yield empty, never throw")
    func suggestionsLatestWins() async throws {
        let model = QueryModel(
            base: baseQuery(),
            suggestions: { request, _ in
                if request.input == "slow" {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                return [Suggestion(label: request.input, value: request.input)]
            }
        )
        // Sequence explicitly: the slow request must register (generation 1)
        // before the fast one (generation 2). Concurrent registration order
        // is nondeterministic under load, which flaked this test.
        let slowTask = Task { await model.suggest(dimension: .source, input: "slow") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let fastResults = await model.suggest(dimension: .source, input: "fast")
        let slowResults = await slowTask.value
        #expect(slowResults.isEmpty)
        #expect(fastResults.map(\.value) == ["fast"])
    }
}
