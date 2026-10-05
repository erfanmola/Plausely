import Testing
@testable import AnalyticsCore
import Foundation

private func utc(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
}

@Suite("dates, timezone, comparison")
struct DateTests {
    let tehran = TimeZone(identifier: "Asia/Tehran")!
    let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
    let utcZone = TimeZone(identifier: "Etc/UTC")!

    @Test("fixed windows are inclusive and anchored to site days")
    func fixedWindows() {
        let today = utc("2026-09-26T20:00:00Z") // 23:30 in Tehran, still Sep 26
        let range = SiteDateRules.range(for: .days7, timeZone: tehran, today: today)!
        #expect(SiteDateRules.isoDay(range.from, in: tehran) == "2026-09-20")
        #expect(SiteDateRules.isoDay(range.to, in: tehran) == "2026-09-26")
    }

    @Test("site midnight differs from device UTC midnight")
    func siteMidnight() {
        // 2026-09-26T20:30Z is already Sep 27 in Tehran (+3:30).
        let late = utc("2026-09-26T20:30:00Z")
        let range = SiteDateRules.range(for: .day, timeZone: tehran, today: late)!
        #expect(SiteDateRules.isoDay(range.from, in: tehran) == "2026-09-27")
        let utcRange = SiteDateRules.range(for: .day, timeZone: utcZone, today: late)!
        #expect(SiteDateRules.isoDay(utcRange.from, in: utcZone) == "2026-09-26")
    }

    @Test("non-hour offsets work (Kathmandu +5:45)")
    func kathmanduOffset() {
        let instant = utc("2026-01-01T18:00:00Z") // 23:45 local, still Jan 1
        let range = SiteDateRules.range(for: .day, timeZone: kathmandu, today: instant)!
        #expect(SiteDateRules.isoDay(range.from, in: kathmandu) == "2026-01-01")
    }

    @Test("historical DST transition keeps calendar correctness (Tehran Mar 2022)")
    func tehranDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tehran
        // Clocks sprang forward 00:00 -> 01:00 on Mar 22 (verified in tzdata).
        let morning = calendar.date(from: DateComponents(year: 2022, month: 3, day: 22, hour: 9))!
        let range = SiteDateRules.range(for: .day, timeZone: tehran, today: morning)!
        #expect(SiteDateRules.isoDay(range.from, in: tehran) == "2022-03-22")
        let next = calendar.date(byAdding: .day, value: 1, to: range.from)!
        let prev = calendar.date(byAdding: .day, value: -1, to: range.from)!
        #expect(SiteDateRules.isoDay(next, in: tehran) == "2022-03-23")
        #expect(SiteDateRules.isoDay(prev, in: tehran) == "2022-03-21")
        #expect(range.from <= morning)
    }

    @Test("leap day and month/year boundaries resolve")
    func boundaries() {
        let leap = utc("2024-02-29T12:00:00Z")
        let feb = SiteDateRules.range(for: .custom(
            from: utc("2024-02-28T00:00:00Z"), to: utc("2024-03-01T00:00:00Z")
        ), timeZone: utcZone, today: leap)!
        #expect(SiteDateRules.isoDay(feb.from, in: utcZone) == "2024-02-28")
        #expect(SiteDateRules.isoDay(feb.to, in: utcZone) == "2024-03-01")
        let mtd = SiteDateRules.range(for: .month, timeZone: utcZone, today: leap)!
        #expect(SiteDateRules.isoDay(mtd.from, in: utcZone) == "2024-02-01")
        let ytd = SiteDateRules.range(for: .year, timeZone: utcZone, today: leap)!
        #expect(SiteDateRules.isoDay(ytd.from, in: utcZone) == "2024-01-01")
        let reversed = SiteDateRules.range(for: .custom(
            from: utc("2024-03-01T00:00:00Z"), to: utc("2024-02-01T00:00:00Z")
        ), timeZone: utcZone, today: leap)
        #expect(reversed == nil)
    }

    @Test("previous period shifts by exact primary length (live-proven)")
    func previousPeriod() {
        let from = utc("2026-09-20T00:00:00Z")
        let to = utc("2026-09-26T00:00:00Z")
        let cmp = SiteDateRules.comparisonRange(for: .previousPeriod, primaryFrom: from, primaryTo: to, timeZone: utcZone)!
        #expect(SiteDateRules.isoDay(cmp.from, in: utcZone) == "2026-09-13")
        #expect(SiteDateRules.isoDay(cmp.to, in: utcZone) == "2026-09-19")
    }

    @Test("year over year shifts one calendar year; custom passes unequal lengths")
    func yoyAndCustom() {
        let from = utc("2026-09-20T00:00:00Z")
        let to = utc("2026-09-26T00:00:00Z")
        let yoy = SiteDateRules.comparisonRange(for: .yearOverYear, primaryFrom: from, primaryTo: to, timeZone: utcZone)!
        #expect(SiteDateRules.isoDay(yoy.from, in: utcZone) == "2025-09-20")
        let custom = SiteDateRules.comparisonRange(
            for: .custom(from: utc("2026-01-01T00:00:00Z"), to: utc("2026-01-31T00:00:00Z")),
            primaryFrom: from, primaryTo: to, timeZone: utcZone)!
        #expect(SiteDateRules.isoDay(custom.to, in: utcZone) == "2026-01-31")
        #expect(Comparison.off.isSupported(for: .days28))
        #expect(!Comparison.previousPeriod.isSupported(for: .realtime))
        #expect(!Comparison.previousPeriod.isSupported(for: .all))
    }

    @Test("interval policy comes from bootstrap, never hardcoded")
    func intervals() {
        let policy = IntervalPolicy(validByPeriod: ["28d": [.day, .week], "day": [.minute, .hour]])
        #expect(policy.isValid(.day, for: .days28))
        #expect(!policy.isValid(.month, for: .days28))
        #expect(!policy.isValid(.day, for: .days30))
    }
}
