import Foundation
import Testing

@testable import AnalyticsCore

@Suite("today estimate floor")
struct TodayEstimateTests {
    private func series(labels: [String], plot: [MetricValue?], comparisonPlot: [MetricValue?]) -> TimeSeries {
        TimeSeries(
            metric: .visitors,
            labels: labels,
            plot: plot,
            comparisonLabels: labels,
            comparisonPlot: comparisonPlot
        )
    }

    @Test("quiet today against loud yesterday never dips below zero")
    func clampsNegativeOffset() {
        // Anchor now at 1 visitor; yesterday at the same minute had 30.
        // Offset is -29; yesterday's small late buckets (5, 2) would go
        // to -24/-27 without the floor — the radar's under-axis dive.
        let labels = ["2026-10-12 14:00", "2026-10-12 15:00", "2026-10-12 18:00", "2026-10-12 20:00"]
        let plot: [MetricValue?] = [.count(20), .count(1), nil, nil]
        let comparison: [MetricValue?] = [.count(25), .count(30), .count(5), .count(2)]
        let points = TodayEstimate.points(
            for: series(labels: labels, plot: plot, comparisonPlot: comparison),
            currentMinute: 15 * 60
        )
        #expect(!points.isEmpty)
        #expect(points.allSatisfy { $0.value >= 0 })
        #expect(points.contains { $0.value == 0 })
    }

    @Test("healthy offset keeps positive estimates untouched")
    func keepsPositiveEstimates() {
        let labels = ["2026-10-12 14:00", "2026-10-12 15:00", "2026-10-12 16:00"]
        let plot: [MetricValue?] = [.count(20), .count(30), nil]
        let comparison: [MetricValue?] = [.count(10), .count(12), .count(14)]
        let points = TodayEstimate.points(
            for: series(labels: labels, plot: plot, comparisonPlot: comparison),
            currentMinute: 15 * 60
        )
        let future = points.filter { $0.minute > 15 * 60 }
        #expect(future.count == 1)
        #expect(future.first?.value == 32)
    }

    @Test("missing comparison yields no estimate")
    func missingComparison() {
        let plain = TimeSeries(metric: .visitors, labels: ["a"], plot: [.count(3)])
        #expect(TodayEstimate.points(for: plain, currentMinute: 60).isEmpty)
    }
}
