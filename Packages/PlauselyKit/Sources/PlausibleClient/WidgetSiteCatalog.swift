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
    private static var file: URL? {
        PlauselySharedContainer.directory?.appending(path: "widget-sites.json")
    }

    public static func all() -> [WidgetSiteOption] {
        guard let file, let data = try? Data(contentsOf: file),
              let sites = try? JSONDecoder().decode([WidgetSiteOption].self, from: data)
        else { return [] }
        return sites.sorted { $0.domain.localizedCaseInsensitiveCompare($1.domain) == .orderedAscending }
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
        guard let file, let data = try? JSONEncoder().encode(sites) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // Widgets can still show previously cached timelines if catalog I/O fails.
        }
    }
}
