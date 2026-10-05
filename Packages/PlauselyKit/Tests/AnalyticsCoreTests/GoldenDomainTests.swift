import Testing
@testable import AnalyticsCore
import Foundation

/// Phase-02.5 reconciliation: the frozen golden window (2026-09-20..26,
/// fixtures/golden-20260920-26) expressed purely in domain types.
/// No JSON is parsed here; DTO decoding lands in phase 03 and must reproduce
/// these exact domain values.
@Suite("golden domain expectations")
struct GoldenDomainTests {
    @Test("frozen overview totals are exact server values")
    func frozenOverview() {
        let overview = Overview(stats: [
            TopStat(metric: .visitors, name: "Unique visitors", value: .count(493)),
            TopStat(metric: .visits, name: "Total visits", value: .count(573)),
            TopStat(metric: .pageviews, name: "Total pageviews", value: .count(4615)),
            TopStat(metric: .viewsPerVisit, name: "Views per visit", value: .decimal(Decimal(string: "8.54")!)),
            TopStat(metric: .bounceRate, name: "Bounce rate", value: .count(66)),
            TopStat(metric: .visitDuration, name: "Visit duration", value: .count(236)),
        ])
        #expect(overview.stats[0].value == .count(493))
        // Uniques never reconstruct from buckets: the math refuses.
        let buckets: [MetricValue?] = [.count(12), .count(10), .count(8), .count(5), .count(8), .count(224), .count(243)]
        #expect(MetricMath.total(buckets, for: .visitors) == .unavailable(.nonAdditive))
    }

    @Test("comparison window is the exact live-proven back-shift")
    func frozenComparison() {
        let stat = TopStat(metric: .visitors, name: "Unique visitors", value: .count(493), comparisonValue: .count(11), change: 4382)
        #expect(stat.comparisonValue == .count(11))
        let overview = Overview(stats: [stat], comparingFrom: "2026-09-13", comparingTo: "2026-09-19")
        #expect(overview.comparingFrom == "2026-09-13")
    }

    @Test("empty conversions window is zero data, not a missing endpoint")
    func emptyConversions() {
        let page = BreakdownPage(rows: [])
        #expect(page.rows.isEmpty)
        let capability = Capability(id: "goals", status: .configurationMissing(reason: "no conversions in window"), evidence: "conversions.frozen.json")
        #expect(!capability.mayAttempt)
    }

    @Test("capability states stay distinct")
    func capabilityStates() {
        #expect(Capability(id: "gsc", status: .unverified, evidence: "").mayAttempt == false)
        #expect(Capability(id: "overview", status: .available, evidence: "top-stats.frozen.json").mayAttempt == true)
        #expect(Capability(id: "props", status: .appMissing, evidence: "").mayAttempt == false)
    }

    @Test("frozen formatter outputs match web display")
    func frozenFormatting() {
        let formatter = MetricFormatter(locale: Locale(identifier: "en_US"))
        #expect(formatter.string(for: .count(4615), as: .pageviews) == "4,615")
        #expect(formatter.string(for: .decimal(Decimal(string: "8.54")!), as: .viewsPerVisit) == "8.54")
        #expect(formatter.string(for: .count(66), as: .bounceRate) == "66%")
        #expect(formatter.string(for: .count(236), as: .visitDuration) == "3m 56s")
    }
}
