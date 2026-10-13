import AnalyticsCore
import Foundation

/// One discovered site: domain plus the role the account holds on it.
public struct SiteSummary: Hashable, Sendable {
    public let domain: String
    public let role: String?
    public let teamIdentifier: String?
    public init(domain: String, role: String? = nil, teamIdentifier: String? = nil) {
        self.domain = domain
        self.role = role
        self.teamIdentifier = teamIdentifier
    }
}

/// Full per-site bootstrap: dashboard snapshot plus resolved IANA timezone.
/// `timeZone` is nil when the settings transport yields nothing — date parity
/// is then blocked and the caller carries offset-only as unverified.
public struct SiteBootstrap: Sendable {
    public let snapshot: BootstrapSnapshot
    public let timeZone: TimeZone?
    public init(snapshot: BootstrapSnapshot, timeZone: TimeZone?) {
        self.snapshot = snapshot
        self.timeZone = timeZone
    }
}

public protocol SiteDiscoveryService: Sendable {
    func discover(account: AccountID) async throws -> [SiteSummary]
    func bootstrap(account: AccountID, domain: String) async throws -> SiteBootstrap
}

/// CE 3.2.1 discovery over authenticated dashboard HTML. Enumeration uses the
/// `/sites` page (complete); per-site role/team come from each bootstrap.
/// Manual domain recovery: `bootstrap` on a user-typed domain either decodes
/// or throws a typed error — unknown sites surface as `.siteUnavailable`.
public struct CE321SiteDiscovery: SiteDiscoveryService, Sendable {
    private let coordinator: SessionCoordinator
    private let transport: HTTPTransport

    public init(coordinator: SessionCoordinator, transport: HTTPTransport) {
        self.coordinator = coordinator
        self.transport = transport
    }

    public func discover(account: AccountID) async throws -> [SiteSummary] {
        let credential = try await coordinator.restore(account: account)
        var request = URLRequest(url: credential.baseURL.appending(path: "sites"))
        for (field, value) in try await coordinator.headers(for: request.url!, account: account) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await transport.send(request, expecting: .html)
        guard let html = String(data: data, encoding: .utf8),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClientError.serverError(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try CE321BootstrapDecoder.siteDomains(html: html).map { SiteSummary(domain: $0) }
    }

    public func bootstrap(account: AccountID, domain: String) async throws -> SiteBootstrap {
        let credential = try await coordinator.restore(account: account)
        let headers = try await coordinator.headers(for: credential.baseURL, account: account)
        func fetch(_ path: String) async throws -> String {
            var request = URLRequest(url: credential.baseURL.appending(path: path))
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let (data, _) = try await transport.send(request, expecting: .html)
            guard let html = String(data: data, encoding: .utf8) else {
                throw ClientError.serverError(status: -1)
            }
            return html
        }
        let snapshot = try CE321BootstrapDecoder.decode(html: try await fetch(domain))
        let settingsHTML = try await fetch("\(domain)/settings/general")
        let timeZone = CE321BootstrapDecoder.timezone(html: settingsHTML)
        return SiteBootstrap(snapshot: snapshot, timeZone: timeZone)
    }
}

/// Passwordless shared dashboard bootstrap over `/share/:domain?auth=`.
/// Password-protected links render the password gate instead of a
/// dashboard container and throw `SharedLinkError.locked` — typed and
/// actionable (unlock with the link password), never attempted silently.
public struct CE321SharedDiscovery: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public struct SharedBootstrap: Sendable {
        public let snapshot: BootstrapSnapshot
        public let limitedSegmentID: Int?
        public init(snapshot: BootstrapSnapshot, limitedSegmentID: Int?) {
            self.snapshot = snapshot
            self.limitedSegmentID = limitedSegmentID
        }
    }

    public func bootstrap(baseURL: URL, domain: String, slug: String, cookies: [CookieRecord] = []) async throws -> SharedBootstrap {
        let builder = try RequestBuilder(baseURL: baseURL)
        var request = builder.get(
            path: "share/\(domain)",
            query: [URLQueryItem(name: "auth", value: slug)]
        )
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await transport.send(request, expecting: .html)
        guard let html = String(data: data, encoding: .utf8),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClientError.siteUnavailable
        }
        if SharedLinkUnlock.isLocked(html: html) {
            throw SharedLinkError.locked
        }
        let snapshot = try CE321BootstrapDecoder.decode(html: html)
        return SharedBootstrap(
            snapshot: snapshot,
            limitedSegmentID: CE321BootstrapDecoder.limitedSegmentID(html: html)
        )
    }
}
