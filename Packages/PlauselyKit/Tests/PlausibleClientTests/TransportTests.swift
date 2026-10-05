import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://stats.example.test/api/stats/x/top-stats")!,
        statusCode: status, httpVersion: nil, headerFields: headers
    )!
}

@Suite("transport errors and requests")
struct TransportTests {
    @Test("manifest status codes map to distinct errors")
    func statusMapping() {
        let notFound = try? JSONSerialization.data(withJSONObject: ["error": "Site does not exist or user does not have sufficient access."])
        #expect(ErrorMapper.map(data: notFound!, response: response(status: 404)) == .siteUnavailable)
        let gsc = try? JSONSerialization.data(withJSONObject: ["error_code": "not_configured"])
        #expect(ErrorMapper.map(data: gsc!, response: response(status: 422)) == .unprocessable(code: "not_configured"))
        let q = try? JSONSerialization.data(withJSONObject: ["error": "Search parameter 'q' is required"])
        #expect(ErrorMapper.map(data: q!, response: response(status: 400)) == .badRequest(message: "Search parameter 'q' is required"))
        #expect(ErrorMapper.map(data: Data("boom".utf8), response: response(status: 500)) == .serverError(status: 500))
        #expect(ErrorMapper.map(data: Data(), response: response(status: 401)) == .loginRequired)
    }

    @Test("HTML login page with HTTP 200 means logged out")
    func htmlLogin() {
        let html = Data("<!DOCTYPE html><html><body>login</body></html>".utf8)
        let json = Data(#"{"top_stats":[]}"#.utf8)
        #expect(ErrorMapper.map(data: html, response: response(status: 200, headers: ["Content-Type": "text/html"])) == .loginRequired)
        #expect(ErrorMapper.map(data: json, response: response(status: 200, headers: ["Content-Type": "application/json"])) == nil)
    }

    @Test("only idempotent failures retry, finitely")
    func retryPolicy() {
        let policy = RetryPolicy(maxRetries: 2, retryAfterCap: 60)
        #expect(policy.delay(for: .transport(code: -1009), attempt: 0) == 1)
        #expect(policy.delay(for: .transport(code: -1009), attempt: 1) == 2)
        #expect(policy.delay(for: .transport(code: -1009), attempt: 2) == nil)
        #expect(policy.delay(for: .rateLimited(retryAfter: 120), attempt: 0) == 60)
        #expect(policy.delay(for: .loginRequired, attempt: 0) == nil)
        #expect(policy.delay(for: .siteUnavailable, attempt: 0) == nil)
        #expect(policy.delay(for: .unprocessable(code: "x"), attempt: 0) == nil)
        #expect(ClientError.cancelled.retryable == false)
    }

    @Test("redirects stay on origin or die")
    func redirectPolicy() {
        let from = URLRequest(url: URL(string: "https://stats.example.test/a")!)
        #expect(RedirectPolicy.allowsRedirect(from: from, to: URL(string: "https://stats.example.test/b")!))
        #expect(!RedirectPolicy.allowsRedirect(from: from, to: URL(string: "https://evil.test/b")!))
        #expect(!RedirectPolicy.allowsRedirect(from: from, to: URL(string: "http://stats.example.test/b")!))
    }

    @Test("builder rejects bad origins and preserves prefixes exactly once")
    func builder() throws {
        #expect(throws: RequestBuilder.BuildError.self) {
            try RequestBuilder(baseURL: URL(string: "ftp://x.test")!)
        }
        #expect(throws: RequestBuilder.BuildError.self) {
            try RequestBuilder(baseURL: URL(string: "https://user@x.test/")!)
        }
        #expect(throws: RequestBuilder.BuildError.self) {
            try RequestBuilder(baseURL: URL(string: "http://x.test/")!)
        }
        let loopback = try RequestBuilder(baseURL: URL(string: "http://localhost:8000")!)
        #expect(loopback.baseURL.host == "localhost")
        let prefixed = try RequestBuilder(baseURL: URL(string: "https://x.test/prefix")!)
        let request = prefixed.get(path: "api/stats/d/referrers/a%2Fb%20c", query: [.init(name: "period", value: "28d")])
        #expect(request.url?.absoluteString == "https://x.test/prefix/api/stats/d/referrers/a%2Fb%20c?period=28d")
    }

    @Test("diagnostics never leak secrets")
    func redaction() {
        var request = URLRequest(url: URL(string: "https://x.test/")!)
        request.setValue("a=b", forHTTPHeaderField: "Cookie")
        request.setValue("t", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let description = RequestBuilder.sanitizedDescription(for: request)
        #expect(!description.contains("a=b"))
        #expect(description.contains("Cookie: <redacted>"))
        #expect(description.contains("Accept: application/json"))
    }
}
