import Foundation

/// Site identity carried by a widget tap so the app can open that exact site.
public struct WidgetSiteDestination: Hashable, Sendable {
    public static let urlScheme = "plausely"

    public let accountID: AccountID
    public let domain: String

    public init(accountID: AccountID, domain: String) {
        self.accountID = accountID
        self.domain = domain
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.urlScheme,
              components.host == "site",
              let accountText = components.queryItems?.first(where: { $0.name == "account" })?.value,
              let accountUUID = UUID(uuidString: accountText),
              let domain = components.queryItems?.first(where: { $0.name == "domain" })?.value,
              !domain.isEmpty else { return nil }
        self.init(accountID: AccountID(rawValue: accountUUID), domain: domain)
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "site"
        components.queryItems = [
            URLQueryItem(name: "account", value: accountID.rawValue.uuidString),
            URLQueryItem(name: "domain", value: domain),
        ]
        return components.url
    }
}
