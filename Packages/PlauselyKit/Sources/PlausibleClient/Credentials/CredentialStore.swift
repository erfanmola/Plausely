import AnalyticsCore
import Foundation

/// Persisted session artifact: server base URL plus first-party cookies.
/// Passwords are never persisted — they live only in the interactive login
/// surface. The secret half of this struct belongs in the Keychain; the
/// account record (base URL, email) belongs in the file store.
public struct SessionCredential: Equatable, Codable, Sendable {
    public let baseURL: URL
    public let cookies: [CookieRecord]
    public let retrievedAt: Date

    public init(baseURL: URL, cookies: [CookieRecord], retrievedAt: Date) {
        self.baseURL = baseURL
        self.cookies = cookies
        self.retrievedAt = retrievedAt
    }
}

/// One cookie in plain-Codable form. Rebuilds via `HTTPCookie(properties:)`;
/// the roundtrip is covered by tests on each toolchain.
public struct CookieRecord: Equatable, Codable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expires: Date?
    public let secure: Bool
    public let httpOnly: Bool

    public init(name: String, value: String, domain: String, path: String, expires: Date? = nil, secure: Bool, httpOnly: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
    }

    public init(cookie: HTTPCookie) {
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expires: cookie.expiresDate,
            secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly
        )
    }

    public func httpCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expires { properties[.expires] = expires }
        properties[.secure] = secure ? "TRUE" : "FALSE"
        // HTTPCookie has no settable HttpOnly property key; the flag is
        // preserved here for diagnostics and re-applied by the cookie jar.
        return HTTPCookie(properties: properties)
    }
}

public enum CredentialStoreError: Error, Equatable {
    case notFound
    case keychain(OSStatus)
    case encoding
}

/// Per-account secret storage. Implementations isolate by account ID and
/// remove everything on account deletion.
public protocol CredentialStore: Sendable {
    func load(for account: AccountID) async throws -> SessionCredential?
    func save(_ credential: SessionCredential, for account: AccountID) async throws
    func remove(for account: AccountID) async throws
}
