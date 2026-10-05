import Testing
@testable import AnalyticsCore
import Foundation

@Suite("report models and formatting")
struct ReportModelTests {
    @Test("series preserves null buckets instead of zero-filling")
    func nullBuckets() {
        let series = TimeSeries(metric: .visitors, labels: ["2026-09-20", "2026-09-21"], plot: [.count(12), nil])
        #expect(series.plot[1] == nil)
        #expect(series.plot[1] != .count(0))
    }

    @Test("comparison context rides along without client math")
    func comparison() {
        let stat = TopStat(metric: .visitors, name: "Unique visitors", value: .count(493), comparisonValue: .count(11), change: 4382)
        #expect(stat.comparisonValue == .count(11))
        #expect(stat.change == 4382)
    }

    @Test("breakdown rows carry only served columns")
    func sparseColumns() {
        let row = BreakdownRow(name: "Google", metrics: [.visitors: .count(727), .percentage: .count(45)])
        #expect(row.metrics[.bounceRate] == nil)
    }

    @Test("formatting is display-only")
    func formatting() {
        let formatter = MetricFormatter(locale: Locale(identifier: "en_US"))
        let value = MetricValue.decimal(Decimal(string: "8.54")!)
        #expect(formatter.string(for: value, as: .viewsPerVisit) == "8.54")
        #expect(value == .decimal(Decimal(string: "8.54")!))
        #expect(formatter.string(for: .count(1600), as: .visitors) == "1,600")
        #expect(formatter.string(for: .count(66), as: .bounceRate) == "66%")
        #expect(formatter.string(for: .count(561), as: .visitDuration) == "9m 21s")
        #expect(formatter.string(for: .unavailable(.noData), as: .visitors) == "–")
    }

    @Test("envelope keeps query identity with value")
    func envelope() {
        let id = QueryID(rawValue: "q1")
        let envelope = ReportEnvelope(queryID: id, value: Overview(stats: []), retrievedAt: Date())
        #expect(envelope.queryID == id)
        #expect(envelope.warnings.isEmpty)
    }
}
