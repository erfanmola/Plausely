import AnalyticsCore
import Foundation
import SwiftSoup

/// Typed failures for password-protected shared links. Passwords are
/// call parameters only — they are never stored anywhere on this path.
/// The unlock cookie is a session-grade secret and lives in the Keychain
/// beside login sessions, never in the account record.
public enum SharedLinkError: Error, Equatable {
    /// The share page renders the password form; the link needs unlocking.
    case locked
    /// The server re-rendered the password form: no unlock cookie was set.
    case wrongPassword
    /// The expected CSRF/authenticate shape is absent (layout changed).
    case malformedForm
}

/// Cookie provider for password-unlocked shared links. Reads the unlock
/// cookie from the Keychain per request so rotation never goes stale.
/// Session accounts never use this; open links have no cookie to read.
public struct SharedLinkCookieProvider: Sendable {
    private let credentials: KeychainCredentialStore
    private let accountID: AccountID

    public init(credentials: KeychainCredentialStore, accountID: AccountID) {
        self.credentials = credentials
        self.accountID = accountID
    }

    public func cookies() async -> [CookieRecord] {
        (try? await credentials.load(for: accountID))?.cookies ?? []
    }
}

/// Password unlock for shared links, verified live against CE 3.2.1:
/// `GET /share/:domain?auth=:slug` renders a password form carrying a
/// `_csrf_token`; `POST /share/:slug/authenticate?auth=:slug` with the
/// token plus password 302-redirects and jars a `shared-link-:slug`
/// cookie, after which stats endpoints accept `?auth=` alongside it.
public enum SharedLinkUnlock {
    public static func cookieName(slug: String) -> String { "shared-link-\(slug)" }

    /// Whether share-page HTML renders the password gate: a password
    /// input plus a form posting at the authenticate route. Both signals
    /// are required so future layouts fail closed into `malformedForm`
    /// instead of misreading.
    public static func isLocked(html: String) -> Bool {
        guard let document = try? SwiftSoup.parse(html) else { return false }
        let password = (try? document.select("input[type=password][name=password]")) ?? Elements()
        let action = ((try? document.select("form[action*=authenticate]").first()?.attr("action")) ?? "")
        return !password.isEmpty() && !action.isEmpty
    }

    public static func csrfToken(html: String) throws -> String {
        guard let document = try? SwiftSoup.parse(html),
              let token = try? document.select("input[name=_csrf_token]").first()?.attr("value"),
              !token.isEmpty
        else { throw SharedLinkError.malformedForm }
        return token
    }

    /// Unlocks the link and returns the session cookie record. Throws
    /// `wrongPassword` when the server sets no cookie, `malformedForm`
    /// when the gate layout is absent, and transport errors otherwise.
    public static func unlock<Transport: CookieReadingTransport>(
        baseURL: URL, domain: String, slug: String, password: String, transport: Transport
    ) async throws -> CookieRecord {
        let builder = try RequestBuilder(baseURL: baseURL)
        let page = builder.get(
            path: "share/\(domain)",
            query: [URLQueryItem(name: "auth", value: slug)],
            accept: "text/html"
        )
        let (data, _) = try await transport.send(page, expecting: .html)
        guard let html = String(data: data, encoding: .utf8), isLocked(html: html) else {
            throw SharedLinkError.malformedForm
        }
        var form = builder.get(
            path: "share/\(encodeSegment(slug))/authenticate",
            query: [URLQueryItem(name: "auth", value: slug)],
            accept: "text/html"
        )
        form.httpMethod = "POST"
        form.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        form.httpBody = Data("password=\(formField(password))&_csrf_token=\(formField(try csrfToken(html: html)))".utf8)
        _ = try await transport.send(form, expecting: .html)
        guard let value = transport.cookieValue(named: cookieName(slug: slug)), !value.isEmpty else {
            throw SharedLinkError.wrongPassword
        }
        return CookieRecord(
            name: cookieName(slug: slug), value: value,
            domain: baseURL.host ?? "", path: "/",
            secure: baseURL.scheme?.lowercased() == "https", httpOnly: true
        )
    }

    /// `application/x-www-form-urlencoded` field encoding: unreserved
    /// characters pass through, space becomes `+`, everything else is
    /// percent-encoded so `+`, `&`, `=` inside passwords survive.
    static func formField(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.unicodeScalars.map { scalar in
            if scalar == " " { return "+" }
            if unreserved.contains(scalar) { return String(scalar) }
            return String(scalar).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }.joined()
    }

    private static func encodeSegment(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
