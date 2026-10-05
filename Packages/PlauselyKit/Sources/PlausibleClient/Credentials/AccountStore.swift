import AnalyticsCore
import Foundation

/// Nonsecret account record. Lives in Application Support as versioned JSON,
/// one file per account. Never holds cookies, passwords, or tokens.
public struct AccountRecord: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let id: AccountID
    public let baseURL: URL
    public let email: String?
    public let createdAt: Date
    public let lastUsedAt: Date
    public let schemaVersion: Int

    public init(id: AccountID, baseURL: URL, email: String?, createdAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.id = id
        self.baseURL = baseURL
        self.email = email
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.schemaVersion = Self.currentSchemaVersion
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
        // Unknown future versions are a typed failure, never silent adoption.
        if record.schemaVersion == 0 {
            return AccountRecord(id: record.id, baseURL: record.baseURL, email: record.email, createdAt: record.createdAt, lastUsedAt: record.lastUsedAt)
        }
        guard record.schemaVersion == AccountRecord.currentSchemaVersion else {
            throw AccountStoreError.corruptStore("schema v\(record.schemaVersion)")
        }
        return record
    }
}
