import Testing
@testable import PlausibleClient
import Foundation

@Suite("realtime headcount transport")
struct CurrentVisitorsTests {
    @Test("bare integers decode")
    func bareInt() throws {
        #expect(try CE321DashboardAdapter.parseCurrentVisitors(Data("12".utf8)) == 12)
        #expect(try CE321DashboardAdapter.parseCurrentVisitors(Data("0".utf8)) == 0)
    }

    @Test("whitespace and quoted numbers decode")
    func tolerantShapes() throws {
        #expect(try CE321DashboardAdapter.parseCurrentVisitors(Data("  7\n".utf8)) == 7)
        #expect(try CE321DashboardAdapter.parseCurrentVisitors(Data("\"9\"".utf8)) == 9)
        #expect(try CE321DashboardAdapter.parseCurrentVisitors(Data(#"{"visitors": 4}"#.utf8)) == 4)
    }

    @Test("garbage stays a typed server error, never zero")
    func garbageFails() {
        #expect(throws: ClientError.self) {
            try CE321DashboardAdapter.parseCurrentVisitors(Data("".utf8))
        }
        #expect(throws: ClientError.self) {
            try CE321DashboardAdapter.parseCurrentVisitors(Data("oops".utf8))
        }
    }

    @Test("leading-dot cookie domains still match the host")
    func cookieDotMatch() {
        func cookie(domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: "k", .value: "v", .domain: domain, .path: "/"])!
        }
        #expect(SessionCoordinator.cookie(cookie(domain: ".stats.example.test"), matchesHost: "stats.example.test"))
        #expect(SessionCoordinator.cookie(cookie(domain: "stats.example.test"), matchesHost: "stats.example.test"))
        #expect(SessionCoordinator.cookie(cookie(domain: ".example.test"), matchesHost: "stats.example.test"))
        #expect(!SessionCoordinator.cookie(cookie(domain: ".other.test"), matchesHost: "stats.example.test"))
        #expect(!SessionCoordinator.cookie(cookie(domain: "ample.test"), matchesHost: "stats.example.test"))
    }
}
