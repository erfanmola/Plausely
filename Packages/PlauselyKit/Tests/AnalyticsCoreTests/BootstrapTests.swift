import Testing
@testable import AnalyticsCore

@Suite("bootstrap")
struct BootstrapTests {
    @Test("account IDs are unique by default")
    func uniqueIDs() {
        #expect(AccountID().rawValue != AccountID().rawValue)
    }
}
