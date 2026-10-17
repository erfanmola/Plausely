import Testing
@testable import AnalyticsCore
@testable import DashboardUI
import Foundation

private func baseQuery(timeZone: TimeZone) -> DashboardQuery {
    DashboardQuery(
        accountID: AccountID(),
        siteID: SiteID(domain: "shop.example"),
        period: .days28,
        comparison: .off,
        filters: .empty,
        includeImported: false,
        interval: .day,
        selectedMetric: .visitors,
        timeZone: timeZone
    )
}

@Suite("period day/range pickers")
@MainActor
struct PeriodPickerTests {
    @Test("setDay anchors arbitrary days, today stays nil-anchored")
    func setDay() throws {
        let zone = TimeZone(identifier: "Asia/Tehran")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let model = QueryModel(base: baseQuery(timeZone: zone))
        let now = Date(timeIntervalSince1970: 1_791_234_000)
        let todayStart = calendar.startOfDay(for: now)
        model.setDay(todayStart, today: now)
        #expect(model.period == .day)
        #expect(model.periodDate == nil)

        let other = calendar.date(byAdding: .day, value: -3, to: todayStart)!
        model.setDay(other, today: now)
        #expect(model.period == .day)
        let anchored = try #require(model.effective)
        #expect(anchored.periodDate != nil)
        #expect(SiteDateRules.isoDay(try #require(anchored.periodDate), in: zone) == SiteDateRules.isoDay(other, in: zone))
    }

    @Test("setCustomRange normalizes to day starts and rejects reversals")
    func setCustomRange() throws {
        let zone = TimeZone(identifier: "UTC")!
        let model = QueryModel(base: baseQuery(timeZone: zone))
        let from = Date(timeIntervalSince1970: 1_750_000_123)
        let to = Date(timeIntervalSince1970: 1_750_100_456)
        model.setCustomRange(from: from, to: to)
        let query = try #require(model.effective)
        guard case .custom(let normFrom, let normTo) = query.period else {
            Issue.record("expected custom period")
            return
        }
        #expect(SiteDateRules.isoDay(normFrom, in: zone) == SiteDateRules.isoDay(from, in: zone))
        #expect(SiteDateRules.isoDay(normTo, in: zone) == SiteDateRules.isoDay(to, in: zone))

        model.setCustomRange(from: to, to: from)
        #expect(model.effective == nil)
        #expect(model.error == .emptyCustomRange)
    }

    @Test("pill names show dates for anchored days and ranges")
    func pillNames() {
        let zone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = Date(timeIntervalSince1970: 1_790_000_000)
        let todayStart = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let other = calendar.date(byAdding: .day, value: -5, to: todayStart)!

        #expect(PeriodLabel.name(period: .day, periodDate: nil, timeZone: zone, today: today) == "Today")
        #expect(PeriodLabel.name(period: .day, periodDate: yesterday, timeZone: zone, today: today) == "Yesterday")
        let otherName = PeriodLabel.name(period: .day, periodDate: other, timeZone: zone, today: today)
        #expect(otherName != "Today" && otherName != "Yesterday" && !otherName.isEmpty)

        let rangeName = PeriodLabel.name(period: .custom(from: other, to: todayStart), periodDate: nil, timeZone: zone, today: today)
        #expect(rangeName.contains("–"))
        let singleRange = PeriodLabel.name(period: .custom(from: other, to: other), periodDate: nil, timeZone: zone, today: today)
        #expect(!singleRange.contains("–"))
    }
}
