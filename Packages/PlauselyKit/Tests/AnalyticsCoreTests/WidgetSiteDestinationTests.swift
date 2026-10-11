import Foundation
import Testing
@testable import AnalyticsCore

@Suite("widget site destination")
struct WidgetSiteDestinationTests {
    @Test("widget URL roundtrips account and encoded site")
    func roundtrip() throws {
        let destination = WidgetSiteDestination(
            accountID: AccountID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
            domain: "shop.example/path?x=1"
        )
        let url = try #require(destination.url)
        #expect(WidgetSiteDestination(url: url) == destination)
        #expect(WidgetSiteDestination(url: URL(string: "https://example.com")!) == nil)
    }
}
