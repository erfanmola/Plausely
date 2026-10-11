import AnalyticsCore
import Foundation

/// A passwordless shared dashboard link: site domain plus the server slug
/// sent as `?auth=` on every request (the dashboard sends both the query
/// param and header; the server reads the param). Slugs are revocable
/// server-side and carry no password. Password-protected links are a typed
/// unsupported case, never attempted silently.
public struct SharedLinkRef: Equatable, Codable, Sendable {
    public let domain: String
    public let slug: String
    public init(domain: String, slug: String) {
        self.domain = domain
        self.slug = slug
    }

    /// Parses pasted dashboard links: `/share/:domain?auth=:slug` or any
    /// dashboard URL carrying `?auth=`. Returns nil for login/session URLs.
    public static func parse(_ text: String) -> (baseURL: URL, link: SharedLinkRef)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host, !host.isEmpty,
              let slug = components.queryItems?.first(where: { $0.name == "auth" })?.value,
              !slug.isEmpty
        else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        // Prefer /share/:domain; fall back to the `site` param or first
        // segment for dashboard URLs (?auth= on /:domain style links).
        let domain = segments.count >= 2 && segments[0] == "share"
            ? segments[1]
            : components.queryItems?.first(where: { $0.name == "site" })?.value
            ?? segments.first
        guard let domain, !domain.isEmpty, !domain.contains("login") else { return nil }
        components.query = nil
        components.path = ""
        guard let base = components.url else { return nil }
        return (base, SharedLinkRef(domain: domain, slug: slug))
    }
}

/// Nonsecret account record. Lives in Application Support as versioned JSON,
/// one file per account. Never holds cookies, passwords, or tokens.
public struct AccountRecord: Equatable, Sendable, Codable {
    public static let currentSchemaVersion = 2
    public let id: AccountID
    public let baseURL: URL
    public let email: String?
    public let sharedLink: SharedLinkRef?
    public let createdAt: Date
    public let lastUsedAt: Date
    public let schemaVersion: Int

    public init(
        id: AccountID, baseURL: URL, email: String?, sharedLink: SharedLinkRef? = nil,
        createdAt: Date = Date(), lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.baseURL = baseURL
        self.email = email
        self.sharedLink = sharedLink
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.schemaVersion = Self.currentSchemaVersion
    }

    private enum Keys: String, CodingKey {
        case id, baseURL, email, sharedLink, createdAt, lastUsedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(AccountID.self, forKey: .id)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        // v1 records predate shared links.
        sharedLink = try container.decodeIfPresent(SharedLinkRef.self, forKey: .sharedLink)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(sharedLink, forKey: .sharedLink)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

public enum AccountStoreError: Error, Equatable {
    case corruptStore(String)
    case io(String)
}

/// Versioned file store for account records with per-account isolation.
/// Removal deletes the record file; callers must also clear the credential
/// store and any cached analytics (see session deletion flow, phase 03.3).
public struct AccountStore: Sendable {
    private let directory: URL

    /// - Parameter directory: production passes Application Support/Plausely;
    ///   tests inject an isolated temporary directory.
    public init(directory: URL) {
        self.directory = directory
    }

    public static func production() throws -> AccountStore {
        if let shared = PlauselySharedContainer.directory {
            let sharedDirectory = shared.appending(path: "Accounts", directoryHint: .isDirectory)
            let legacyBase = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appending(path: "Plausely", directoryHint: .isDirectory)
            // Preserve accounts created before the widget app group existed.
            try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
            if let oldFiles = try? FileManager.default.contentsOfDirectory(at: legacyBase, includingPropertiesForKeys: nil) {
                for oldFile in oldFiles where oldFile.pathExtension == "json" {
                    let newFile = sharedDirectory.appending(path: oldFile.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: newFile.path) {
                        try? FileManager.default.copyItem(at: oldFile, to: newFile)
                    }
                }
            }
            return AccountStore(directory: sharedDirectory)
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return AccountStore(directory: base.appending(path: "Plausely", directoryHint: .isDirectory))
    }

    private func file(for id: AccountID) -> URL {
        directory.appending(path: "\(id.rawValue.uuidString).json")
    }

    public func save(_ record: AccountRecord) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: file(for: record.id), options: .atomic)
        } catch let error as AccountStoreError {
            throw error
        } catch {
            throw AccountStoreError.io(error.localizedDescription)
        }
    }

    public func load(id: AccountID) throws -> AccountRecord? {
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            var record = try JSONDecoder().decode(AccountRecord.self, from: data)
            record = try migrate(record)
            return record
        } catch let error as AccountStoreError {
            throw error
        } catch {
            throw AccountStoreError.corruptStore(id.rawValue.uuidString)
        }
    }

    public func allIDs() throws -> [AccountID] {
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .compactMap { url in
                    guard url.pathExtension == "json", let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
                    return AccountID(rawValue: uuid)
                }
        } catch {
            throw AccountStoreError.io(error.localizedDescription)
        }
    }

    public func remove(id: AccountID) throws {
        do {
            guard FileManager.default.fileExists(atPath: file(for: id).path) else { return }
            try FileManager.default.removeItem(at: file(for: id))
        } catch {
            throw AccountStoreError.io(error.localizedDescription)
        }
    }

    private func migrate(_ record: AccountRecord) throws -> AccountRecord {
        // v0 had no schemaVersion field (decoded as 0): stamp current version.
        // v1 predates shared links (decoded as nil): adopt as-is.
        // Unknown future versions are a typed failure, never silent adoption.
        if record.schemaVersion == 0 || record.schemaVersion == 1 {
            return AccountRecord(
                id: record.id, baseURL: record.baseURL, email: record.email,
                sharedLink: record.sharedLink, createdAt: record.createdAt, lastUsedAt: record.lastUsedAt
            )
        }
        guard record.schemaVersion == AccountRecord.currentSchemaVersion else {
            throw AccountStoreError.corruptStore("schema v\(record.schemaVersion)")
        }
        return record
    }
}
