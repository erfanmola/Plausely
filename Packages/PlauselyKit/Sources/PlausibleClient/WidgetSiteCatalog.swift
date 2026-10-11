import AnalyticsCore
import Foundation

/// Non-secret widget choices shared by the app and its WidgetKit extensions.
/// Session cookies remain in the Keychain.
public struct WidgetSiteOption: Codable, Hashable, Sendable, Identifiable {
    public let accountID: AccountID
    public let domain: String
    public let teamID: String?
    public let timeZoneID: String?

    public var id: String { "\(accountID.rawValue.uuidString)|\(domain)" }

    public init(accountID: AccountID, domain: String, teamID: String?, timeZoneID: String?) {
        self.accountID = accountID
        self.domain = domain
        self.teamID = teamID
        self.timeZoneID = timeZoneID
    }
}

public enum PlauselySharedContainer {
    public static let groupID = "group.ir.developex.Plausely"

    public static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
}

public enum WidgetSiteCatalog {
    private static let sharedKeychainService = "ir.developex.Plausely.widget-sites"

    private static var file: URL? {
        PlauselySharedContainer.directory?.appending(path: "widget-sites.json")
    }

    public static func all() -> [WidgetSiteOption] {
        var sites = decode(file.flatMap { try? Data(contentsOf: $0) })
        sites.append(contentsOf: decode(SharedKeychainDataStore.load(
            service: sharedKeychainService,
            key: "catalog"
        )))
        var byID: [String: WidgetSiteOption] = [:]
        for site in sites { byID[site.id] = site }
        return byID.values.sorted {
            $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending
        }
    }

    public static func replace(accountID: AccountID, with sites: [WidgetSiteOption]) {
        var current = all().filter { $0.accountID != accountID }
        current.append(contentsOf: sites)
        save(current)
    }

    public static func remove(accountID: AccountID) {
        save(all().filter { $0.accountID != accountID })
    }

    private static func save(_ sites: [WidgetSiteOption]) {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        if let file {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                // Fall through to the shared keychain for unsigned App Groups.
            }
        }
        try? SharedKeychainDataStore.save(data, service: sharedKeychainService, key: "catalog")
    }

    private static func decode(_ data: Data?) -> [WidgetSiteOption] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([WidgetSiteOption].self, from: data)) ?? []
    }
}
