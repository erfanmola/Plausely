import AnalyticsCore
import Foundation

/// Per-account session lifecycle. An actor serializes overlapping
/// login/logout/refresh races: concurrent callers queue instead of issuing
/// parallel logins. Secrets live only in `CredentialStore`; this coordinator
/// holds the in-memory validity flag and derives request headers.
public actor SessionCoordinator {
    private let bridge: WebLoginBridge
    private let credentials: CredentialStore
    private let accounts: AccountStore
    private let transport: HTTPTransport
    private var invalidated: Set<String> = []
    /// In-flight logins by account. Concurrent logins for one account join
    /// the same task instead of opening parallel browser sessions.
    private var inflightLogins: [String: Task<SessionCredential, Error>] = [:]

    public init(bridge: WebLoginBridge, credentials: CredentialStore, accounts: AccountStore, transport: HTTPTransport) {
        self.bridge = bridge
        self.credentials = credentials
        self.accounts = accounts
        self.transport = transport
    }

    public enum SessionError: Error, Equatable {
        case unknownAccount
        case sessionInvalid
    }

    /// Interactive login. Persists the session secret and account record.
    /// Concurrent calls for the same account coalesce onto one bridge login.
    @discardableResult
    public func login(account: AccountID, baseURL: URL, email: String, password: String) async throws -> SessionCredential {
        let key = account.rawValue.uuidString
        if let inflight = inflightLogins[key] {
            return try await inflight.value
        }
        let task = Task {
            try await self.performLogin(account: account, baseURL: baseURL, email: email, password: password)
        }
        inflightLogins[key] = task
        defer { inflightLogins.removeValue(forKey: key) }
        return try await task.value
    }

    private func performLogin(account: AccountID, baseURL: URL, email: String, password: String) async throws -> SessionCredential {
        let cookies = try await bridge.loginCookies(email: email, password: password)
        let credential = SessionCredential(
            baseURL: baseURL,
            cookies: cookies.map(CookieRecord.init(cookie:)),
            retrievedAt: Date()
        )
        try await credentials.save(credential, for: account)
        let record = AccountRecord(id: account, baseURL: baseURL, email: email)
        try accounts.save(record)
        invalidated.remove(account.rawValue.uuidString)
        return credential
    }

    /// Restores a persisted session without touching the password.
    public func restore(account: AccountID) async throws -> SessionCredential {
        guard let credential = try await credentials.load(for: account) else {
            throw SessionError.unknownAccount
        }
        if invalidated.contains(account.rawValue.uuidString) {
            throw SessionError.sessionInvalid
        }
        return credential
    }

    /// Cookie headers for an authenticated request.
    public func headers(for url: URL, account: AccountID) async throws -> [String: String] {
        let credential = try await restore(account: account)
        let cookies = credential.cookies.compactMap { $0.httpCookie() }
        guard let host = url.host else { return [:] }
        return HTTPCookie.requestHeaderFields(with: cookies.filter {
            Self.cookie($0, matchesHost: host)
        })
    }

    /// Domain match tolerant of leading-dot cookie domains (`.example.com`).
    /// `HTTPCookie.domain` preserves the leading dot while `URL.host` never
    /// has one, so a naive equality/suffix check drops valid session cookies
    /// and realtime (or any) polling reads as logged out.
    static func cookie(_ cookie: HTTPCookie, matchesHost host: String) -> Bool {
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        guard !domain.isEmpty else { return false }
        let host = host.lowercased()
        if host == domain { return true }
        return host.hasSuffix("." + domain)
    }

    /// Marks the session dead after a `.loginRequired` failure so the next
    /// use prompts re-login instead of replaying a dead cookie.
    public func noteLoginRequired(account: AccountID) {
        invalidated.insert(account.rawValue.uuidString)
    }

    public func isValid(account: AccountID) -> Bool {
        !invalidated.contains(account.rawValue.uuidString)
    }

    /// Server logout followed by local secret removal. The nonsecret account
    /// record is kept so the user can sign in again without retyping the URL.
    /// Runs even for invalidated sessions: logout is cleanup, not proof.
    public func logout(account: AccountID) async throws {
        if let credential = try await credentials.load(for: account) {
            let url = credential.baseURL.appending(path: "logout")
            var request = URLRequest(url: url)
            let cookies = credential.cookies.compactMap { $0.httpCookie() }
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            _ = try? await transport.send(request)
        }
        try await credentials.remove(for: account)
        invalidated.insert(account.rawValue.uuidString)
    }

    /// Full account deletion: secret, record, and validity flag.
    /// Analytics caches clear through the cache owner (phase 08).
    public func deleteAccount(account: AccountID) async throws {
        try await credentials.remove(for: account)
        try accounts.remove(id: account)
        invalidated.remove(account.rawValue.uuidString)
    }
}
