import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

private enum UnlockFixture {
    static let slug = "abc123"
    static let csrf = "csrf-token-value"
    static let lockedHTML = """
    <html><body>
    <form action="/share/abc123/authenticate?auth=abc123" method="post">
    <input name="_csrf_token" type="hidden" hidden value="csrf-token-value">
    <input type="password" name="password" id="password">
    </form></body></html>
    """
    static let openHTML = """
    <html><body><div id="stats-react-container" data-domain="shop.example"></div></body></html>
    """
}

private final class FakeCookieTransport: CookieReadingTransport, @unchecked Sendable {
    var getHTML: String
    var postSetsCookie: Bool
    nonisolated(unsafe) var postedBodies: [String] = []
    nonisolated(unsafe) var jar: [String: String]

    init(getHTML: String, postSetsCookie: Bool = true, jar: [String: String] = [:]) {
        self.getHTML = getHTML
        self.postSetsCookie = postSetsCookie
        self.jar = jar
    }

    func send(_ request: URLRequest, expecting: ContentKind) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        if request.httpMethod == "POST" {
            postedBodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            if postSetsCookie {
                jar[SharedLinkUnlock.cookieName(slug: UnlockFixture.slug)] = "cookie-value"
            }
            return (Data(UnlockFixture.lockedHTML.utf8), response)
        }
        return (Data(getHTML.utf8), response)
    }

    func cookieValue(named name: String) -> String? { jar[name] }
}

private func baseURL() -> URL { URL(string: "https://stats.example.test")! }

@Suite("password-protected shared links")
struct SharedLinkUnlockTests {
    @Test("lock detection needs both the password field and the authenticate form")
    func lockDetection() {
        #expect(SharedLinkUnlock.isLocked(html: UnlockFixture.lockedHTML))
        #expect(!SharedLinkUnlock.isLocked(html: UnlockFixture.openHTML))
        #expect(!SharedLinkUnlock.isLocked(html: "not html at all"))
        #expect(!SharedLinkUnlock.isLocked(html: "<html><body><input type=\"password\" name=\"other\"></body></html>"))
    }

    @Test("CSRF token extracts, or fails typed when absent")
    func csrfToken() throws {
        #expect(try SharedLinkUnlock.csrfToken(html: UnlockFixture.lockedHTML) == UnlockFixture.csrf)
        #expect(throws: SharedLinkError.malformedForm) {
            try SharedLinkUnlock.csrfToken(html: UnlockFixture.openHTML)
        }
    }

    @Test("form fields encode reserved characters, space becomes plus")
    func formEncoding() {
        #expect(SharedLinkUnlock.formField("plainAZ09-._~") == "plainAZ09-._~")
        #expect(SharedLinkUnlock.formField("a+b&c=d e") == "a%2Bb%26c%3Dd+e")
    }

    @Test("unlock posts the token and password, returning the cookie record")
    func unlockSuccess() async throws {
        let transport = FakeCookieTransport(getHTML: UnlockFixture.lockedHTML)
        let record = try await SharedLinkUnlock.unlock(
            baseURL: baseURL(), domain: "shop.example", slug: UnlockFixture.slug,
            password: "p@ss w+rd", transport: transport
        )
        #expect(record.name == "shared-link-abc123")
        #expect(record.value == "cookie-value")
        #expect(record.domain == "stats.example.test")
        #expect(record.secure)
        let body = try #require(transport.postedBodies.first)
        #expect(body.contains("password=p%40ss+w%2Brd"))
        #expect(body.contains("_csrf_token=csrf-token-value"))
    }

    @Test("no cookie after POST means wrong password")
    func wrongPassword() async {
        let transport = FakeCookieTransport(getHTML: UnlockFixture.lockedHTML, postSetsCookie: false)
        await #expect(throws: SharedLinkError.wrongPassword) {
            try await SharedLinkUnlock.unlock(
                baseURL: baseURL(), domain: "shop.example", slug: UnlockFixture.slug,
                password: "nope", transport: transport
            )
        }
    }

    @Test("unlocking an open page fails typed, never silently")
    func openPageUnlock() async {
        let transport = FakeCookieTransport(getHTML: UnlockFixture.openHTML)
        await #expect(throws: SharedLinkError.malformedForm) {
            try await SharedLinkUnlock.unlock(
                baseURL: baseURL(), domain: "shop.example", slug: UnlockFixture.slug,
                password: "whatever", transport: transport
            )
        }
        #expect(transport.postedBodies.isEmpty)
    }
}
