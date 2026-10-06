import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

enum FixtureError: Error {
    case missing(String)
}

@Suite("DTO decoding")
struct DTODecodingTests {
    @Test("top-stats decodes with warnings and comparison context")
    func topStats() throws {
        let dto = try JSONDecoder().decode(TopStatsDTO.self, from: fixture("top-stats.day"))
        #expect(dto.topStats.count == 6)
        #expect(dto.topStats[0].name == "Unique visitors")
        #expect(dto.meta.importsIncluded == false)
        let visitors = try dto.topStats[0].value.metricValue()
        #expect(visitors == .count(1600))
        let ratio = try dto.topStats[3].value.metricValue()
        #expect(ratio == .decimal(Decimal(string: "0.88")!))
    }

    @Test("main-graph preserves null buckets positionally")
    func mainGraph() throws {
        let dto = try JSONDecoder().decode(MainGraphDTO.self, from: fixture("main-graph.sample"))
        #expect(dto.labels.count == 2)
        #expect(dto.plot.count == 2)
        #expect(dto.metric == "visitors")
        #expect(dto.comparisonPlot?.count == 2)
        // Null bucket decodes as a genuine gap: present, not zero.
        #expect(dto.plot[1] == nil)
        #expect(dto.plot[1] != .int(0))
    }

    @Test("explicit nulls in metric maps become unavailable, not zero")
    func nullMetrics() throws {
        let raw = #"{"results": [{"name": "X", "visitors": 5, "visit_duration": null}]}"#
        let dto = try JSONDecoder().decode(BreakdownDTO.self, from: Data(raw.utf8))
        let duration = try dto.results[0].metrics["visit_duration"]?.metricValue()
        #expect(duration == .unavailable(.null))
    }

    @Test("every breakdown family decodes with its columns")
    func breakdowns() throws {
        for name in ["sources", "pages", "conversions", "browsers", "channels"] {
            let dto = try JSONDecoder().decode(BreakdownDTO.self, from: fixture("\(name).day"))
            #expect(!dto.results.isEmpty, "\(name) empty")
            #expect(!dto.results[0].name.isEmpty, "\(name) nameless")
        }
        let conversions = try JSONDecoder().decode(BreakdownDTO.self, from: fixture("conversions.day"))
        #expect(conversions.results[0].metrics["events"] != nil)
        #expect(conversions.results[0].metrics["conversion_rate"] != nil)
    }

    @Test("suggestions decode as label/value pairs")
    func suggestions() throws {
        let list = try JSONDecoder().decode([Suggestion].self, from: fixture("suggestions.sample"))
        #expect(list.count == 2)
        #expect(list[0].label == "Google")
    }

    @Test("missing required keys fail; additive fields are tolerated")
    func strictness() throws {
        var raw = try JSONSerialization.jsonObject(with: fixture("sources.day")) as? [String: Any] ?? [:]
        raw.removeValue(forKey: "results")
        let missing = try JSONSerialization.data(withJSONObject: raw)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BreakdownDTO.self, from: missing)
        }
        var extra = try JSONSerialization.jsonObject(with: fixture("sources.day")) as? [String: Any] ?? [:]
        extra["future_field"] = ["nested": true]
        let tolerated = try JSONSerialization.data(withJSONObject: extra)
        #expect(throws: Never.self) {
            try JSONDecoder().decode(BreakdownDTO.self, from: tolerated)
        }
    }

    @Test("strings where numbers belong are malformed")
    func malformedNumbers() throws {
        let bad = JSONScalar.string("oops")
        #expect(throws: DecodingError.self) { try bad.metricValue() }
        #expect(try JSONScalar.null.metricValue() == .unavailable(.null))
        #expect(try JSONScalar.int(7).metricValue() == .count(7))
    }
}
