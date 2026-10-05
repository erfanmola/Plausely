import Testing
@testable import AnalyticsCore
import Foundation

@Suite("metric values")
struct MetricValueTests {
    @Test("zero is distinct from unavailable")
    func zeroVsUnavailable() {
        #expect(MetricValue.count(0).isZero)
        #expect(!MetricValue.unavailable(.null).isZero)
        #expect(!MetricValue.unavailable(.noData).hasNumber)
        #expect(MetricValue.decimal(Decimal(string: "2.85")!).hasNumber)
    }

    @Test("summing unique visitors is refused, not fabricated")
    func nonAdditiveRefused() {
        let total = MetricMath.total([.count(12), .count(10)], for: .visitors)
        #expect(total == .unavailable(.nonAdditive))
        let visits = MetricMath.total([.count(27), .count(52)], for: .visits)
        #expect(visits == .unavailable(.nonAdditive))
    }

    @Test("additive counts sum; unavailable propagates")
    func additiveSums() {
        #expect(MetricMath.total([.count(99), .count(691)], for: .pageviews) == .count(790))
        #expect(MetricMath.total([nil, .count(5)], for: .pageviews) == .count(5))
        #expect(MetricMath.total([.count(5), .unavailable(.null)], for: .pageviews) == .unavailable(.null))
    }

    @Test("mixed int and decimal keeps precision")
    func mixedPrecision() {
        let total = MetricMath.total([.count(3), .decimal(Decimal(string: "0.5")!)], for: .events)
        #expect(total == .decimal(Decimal(string: "3.5")!))
    }

    @Test("rates are never summed")
    func ratesRefused() {
        #expect(MetricMath.total([.count(56), .count(60)], for: .bounceRate) == .unavailable(.nonAdditive))
        #expect(MetricMath.total([.count(493)], for: .conversionRate) == .unavailable(.nonAdditive))
    }
}
