import AnalyticsCore
import Foundation
import Testing

/// Server labels carry full timestamps; display drops what the period
/// makes redundant. UTC throughout; unparseable input passes through.
private let utc = TimeZone(identifier: "UTC")!

@Suite("bucket label display")
struct BucketLabelsTests {
    @Test("intraday periods render clock time without seconds")
    func intraday() {
        #expect(BucketLabels.display("2026-10-05 14:00:00", for: .day, in: utc) == "14:00")
        #expect(BucketLabels.display("2026-10-05 00:00:00", for: .day, in: utc) == "00:00")
        #expect(BucketLabels.display("2026-10-05 09:30:00", for: .realtime, in: utc) == "09:30")
    }

    @Test("coarser periods render midnight buckets as days")
    func coarse() {
        #expect(BucketLabels.display("2026-10-05 00:00:00", for: .days28, in: utc) == "5 Oct")
        #expect(BucketLabels.display("2026-10-05", for: .days28, in: utc) == "5 Oct")
        #expect(BucketLabels.display("2026-10-05 14:00:00", for: .days7, in: utc) == "14:00")
    }

    @Test("mock short labels and unknown shapes pass through")
    func passthrough() {
        #expect(BucketLabels.display("00:00", for: .day, in: utc) == "00:00")
        #expect(BucketLabels.display("12", for: .days28, in: utc) == "12")
        #expect(BucketLabels.display("", for: .day, in: utc) == "")
    }
}
