import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

/// Synthetic HTML goldens (no production data). Shapes mirror the pinned
/// CE 3.2.1 templates with scrubbed values.
private let bootstrapHTML = """
<div id="stats-react-container" data-domain="shop.example.test" data-offset="12600" data-has-goals="true" data-conversions-opted-out="false" data-funnels-opted-out="false" data-props-opted-out="false" data-funnels-available="true" data-props-available="true" data-site-segments-available="true" data-revenue-goals="[]" data-funnels="[]" data-has-props="true" data-logged-in="true" data-stats-begin="2026-09-18" data-native-stats-begin="2026-09-18" data-embedded="" data-is-dbip="true" data-current-user-role="owner" data-current-user-id="1" data-flags="{}" data-segments="[]" data-valid-intervals-by-period="{&quot;28d&quot;:[&quot;day&quot;,&quot;week&quot;]}" data-is-consolidated-view="false" data-consolidated-view-available="false" data-team-identifier="team-1" data-limited-to-segment-id="null"></div>
"""

private let sitesHTML = """
<html><body><div data-domain="b.example.test"></div><div data-domain="a.example.test"></div><div data-domain="a.example.test"></div></body></html>
"""

private let settingsHTML = """
<html><body><select id="site_timezone"><option value="Etc/UTC">UTC</option><option offset="-210" selected value="Asia/Tehran">Tehran</option></select></body></html>
"""

@Suite("bootstrap and discovery decoding")
struct BootstrapTests {
    @Test("container decodes with exact values")
    func decodes() throws {
        let snapshot = try CE321BootstrapDecoder.decode(html: bootstrapHTML)
        #expect(snapshot.domain == "shop.example.test")
        #expect(snapshot.utcOffsetSeconds == 12600)
        #expect(snapshot.hasGoals && snapshot.hasProps)
        #expect(snapshot.statsBegin == "2026-09-18")
        #expect(snapshot.intervals.isValid(.day, for: .days28))
        #expect(!snapshot.intervals.isValid(.month, for: .days28))
        #expect(snapshot.segmentCount == 0)
        #expect(snapshot.currentUserRole == "owner")
        #expect(snapshot.teamIdentifier == "team-1")
    }

    @Test("missing container is a typed layout failure")
    func unknownLayout() {
        #expect(throws: BootstrapError.unknownLayout) {
            try CE321BootstrapDecoder.decode(html: "<html><body>nope</body></html>")
        }
        #expect(throws: BootstrapError.self) {
            try CE321BootstrapDecoder.decode(html: "<div id=\"stats-react-container\" data-domain=\"x\"></div>")
        }
    }

    @Test("unknown interval names fail instead of guessing")
    func unknownInterval() {
        let bad = bootstrapHTML.replacingOccurrences(of: "&quot;day&quot;", with: "&quot;fortnight&quot;")
        #expect(throws: BootstrapError.self) {
            try CE321BootstrapDecoder.decode(html: bad)
        }
    }

    @Test("sites list dedupes and sorts; timezone resolves IANA")
    func sitesAndTimezone() throws {
        #expect(try CE321BootstrapDecoder.siteDomains(html: sitesHTML) == ["a.example.test", "b.example.test"])
        #expect(CE321BootstrapDecoder.timezone(html: settingsHTML)?.identifier == "Asia/Tehran")
        #expect(CE321BootstrapDecoder.timezone(html: "<html></html>") == nil)
    }
}
