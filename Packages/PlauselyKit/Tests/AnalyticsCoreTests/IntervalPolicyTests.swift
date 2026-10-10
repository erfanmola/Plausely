import AnalyticsCore
import Foundation
import Testing

/// Dashboard-faithful interval derivation (`interval-picker.tsx`
/// `getCurrentInterval`): keep the current interval when valid,
/// otherwise the dashboard default. Frozen clock + UTC throughout.
private let utc = TimeZone(identifier: "UTC")!
private let frozen = Date(timeIntervalSince1970: 1_790_000_000)
private let fullPolicy = IntervalPolicy(validByPeriod: [
    "realtime": [.minute],
    "day": [.minute, .hour],
    "7d": [.hour, .day],
    "28d": [.day, .week],
    "30d": [.day, .week],
    "91d": [.day, .week],
    "month": [.day, .week],
    "year": [.day, .week, .month],
    "6mo": [.day, .week, .month],
    "12mo": [.day, .week, .month],
    "all": [.week, .month],
    "custom": [.day, .week, .month],
])

@Suite("interval policy derivation")
struct IntervalPolicyTests {
    @Test("valid current interval is kept")
    func keepsValid() {
        #expect(fullPolicy.currentInterval(.day, for: .days28, timeZone: utc, today: frozen) == .day)
        #expect(fullPolicy.currentInterval(.hour, for: .day, timeZone: utc, today: frozen) == .hour)
        #expect(fullPolicy.currentInterval(.month, for: .year, timeZone: utc, today: frozen) == .month)
    }

    @Test("stale intervals fall back to dashboard defaults")
    func staleFallsBack() {
        #expect(fullPolicy.currentInterval(.day, for: .day, timeZone: utc, today: frozen) == .hour)
        #expect(fullPolicy.currentInterval(.day, for: .realtime, timeZone: utc, today: frozen) == .minute)
        #expect(fullPolicy.currentInterval(.day, for: .days7, timeZone: utc, today: frozen) == .day)
        #expect(fullPolicy.currentInterval(.day, for: .months12, timeZone: utc, today: frozen) == .day)
        #expect(fullPolicy.currentInterval(.hour, for: .months12, timeZone: utc, today: frozen) == .month)
        #expect(fullPolicy.currentInterval(.hour, for: .days28, timeZone: utc, today: frozen) == .day)
    }

    @Test("custom ranges follow the span rule")
    func customSpans() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let short = calendar.date(byAdding: .day, value: 6, to: frozen)!
        let medium = calendar.date(byAdding: .day, value: 60, to: frozen)!
        let long = calendar.date(byAdding: .day, value: 400, to: frozen)!
        #expect(fullPolicy.currentInterval(.month, for: .custom(from: frozen, to: short), timeZone: utc, today: frozen) == .day)
        #expect(fullPolicy.currentInterval(.day, for: .custom(from: frozen, to: medium), timeZone: utc, today: frozen) == .day)
        #expect(fullPolicy.currentInterval(.day, for: .custom(from: frozen, to: long), timeZone: utc, today: frozen) == .month)
    }

    @Test("table default applies even with a sparse map")
    func sparseMapDefault() {
        let sparse = IntervalPolicy(validByPeriod: ["28d": [.day]])
        #expect(sparse.currentInterval(.week, for: .year, timeZone: utc, today: frozen) == .month)
        #expect(sparse.currentInterval(.week, for: .month, timeZone: utc, today: frozen) == .week)
    }

    @Test("dashboard table default wins even when the map omits it")
    func blindDefault() {
        let minuteOnly = IntervalPolicy(validByPeriod: ["day": [.minute]])
        #expect(minuteOnly.currentInterval(.day, for: .day, timeZone: utc, today: frozen) == .hour)
    }
}
