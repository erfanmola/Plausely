import Foundation

/// Typed client failures. Every case preserves the distinction the UI needs:
/// retry, re-login, setup prompt, or honest error — never a silent default.
public enum ClientError: Error, Equatable {
    /// DNS/offline/timeout/TLS and other transport failures (no response).
    case transport(code: Int)
    /// Login session is missing or rejected. Covers the JSON 404
    /// site-or-denied body AND the HTML login page served with HTTP 200.
    case loginRequired
    /// Site unknown or caller lacks access (server intentionally ambiguous).
    case siteUnavailable
    /// 400 with the server's message (e.g. missing suggestion `q`).
    case badRequest(message: String)
    /// 422 with machine code (e.g. GSC `not_configured`).
    case unprocessable(code: String)
    /// 429 with optional Retry-After seconds.
    case rateLimited(retryAfter: Int?)
    /// 5xx or undecodable error body.
    case serverError(status: Int)
    /// Malformed URL, unsupported scheme, userinfo/fragment present.
    case invalidRequest(String)
    /// Redirect would leave the proven origin (cookies never forwarded).
    case redirectViolation(to: String)
    /// Caller cancelled; not an error banner downstream.
    case cancelled

    /// Only idempotent reads with these failures may retry, finitely.
    public var retryable: Bool {
        switch self {
        case .transport, .rateLimited, .serverError: return true
        default: return false
        }
    }
}

/// Maps HTTP responses to `ClientError` using the verified manifest.
/// Bodies follow the server's `{error, error_code}` shape; unknown required
/// content becomes `.serverError`, never a success-looking empty result.
/// The HTML-login heuristic applies only to JSON-contract calls: dashboard
/// HTML pages legitimately return 200 text/html and must pass through.
/// Expected body contract for a request. JSON-contract calls treat an HTML
/// login page (HTTP 200) as logged-out; dashboard HTML pages pass through.
public enum ContentKind: Sendable {
    case json
    case html
}

public enum ErrorMapper {
    public static func map(data: Data, response: HTTPURLResponse, expecting: ContentKind = .json) -> ClientError? {
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            return .rateLimited(retryAfter: retryAfter)
        }
        guard (200...299).contains(response.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let message = body["error"] as? String ?? ""
            let code = body["error_code"] as? String ?? ""
            switch response.statusCode {
            case 400: return .badRequest(message: message)
            case 401: return .loginRequired
            case 403, 404: return .siteUnavailable
            case 422: return .unprocessable(code: code.isEmpty ? message : code)
            default: return .serverError(status: response.statusCode)
            }
        }
        if expecting == .json, isHTMLLogin(data: data, response: response) {
            return .loginRequired
        }
        return nil
    }

    /// Browser navigation can return the login page with HTTP 200 instead of
    /// a JSON payload. The API contract is JSON; HTML here means logged out.
    public static func isHTMLLogin(data: Data, response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.lowercased().contains("text/html") else { return false }
        let prefix = String(data: data.prefix(512), encoding: .utf8) ?? ""
        return prefix.lowercased().contains("<!doctype html") || prefix.lowercased().contains("<html")
    }
}
