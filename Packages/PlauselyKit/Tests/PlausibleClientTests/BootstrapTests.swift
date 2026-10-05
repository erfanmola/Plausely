import Testing
@testable import PlausibleClient

@Suite("bootstrap")
struct ClientBootstrapTests {
    @Test("transport is explicitly unimplemented")
    func unimplemented() {
        #expect(PlausibleClientBootstrap.notImplemented == "phase-03")
    }
}
