import CryptoKit
import Foundation
import Security

/// App-lock secret: salted SHA-256 of the 4-digit passcode plus the
/// biometric preference. The passcode itself is never persisted anywhere;
/// verification re-hashes the attempt. Stored as one Keychain record
/// (shared group when configured, so the widget gate reads the same
/// truth), never in UserDefaults or files.
public struct AppLockRecord: Equatable, Codable, Sendable {
    public let salt: Data
    public let hash: Data
    public let biometricEnabled: Bool

    public init(salt: Data, hash: Data, biometricEnabled: Bool) {
        self.salt = salt
        self.hash = hash
        self.biometricEnabled = biometricEnabled
    }
}

public enum AppLockStoreError: Error, Equatable {
    case encoding
    case invalidPasscode
    case keychain(OSStatus)
}

public enum AppLockStore {
    public static let service = "ir.developex.Plausely.applock"
    public static let key = "config"

    public static func digest(passcode: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(passcode.utf8))
        return Data(hasher.finalize())
    }

    public static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes)
    }

    public static func save(_ record: AppLockRecord, service: String = service, key: String = key, accessGroup: String? = nil) throws {
        guard let data = try? JSONEncoder().encode(record) else {
            throw AppLockStoreError.encoding
        }
        var query = baseQuery(service: service, key: key, accessGroup: accessGroup)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AppLockStoreError.keychain(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw AppLockStoreError.keychain(status) }
    }

    public static func load(service: String = service, key: String = key, accessGroup: String? = nil) -> AppLockRecord? {
        var query = baseQuery(service: service, key: key, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let record = try? JSONDecoder().decode(AppLockRecord.self, from: data)
        else { return nil }
        return record
    }

    public static func remove(service: String = service, key: String = key, accessGroup: String? = nil) throws {
        let status = SecItemDelete(baseQuery(service: service, key: key, accessGroup: accessGroup) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppLockStoreError.keychain(status)
        }
    }

    /// Constant-shape verification: returns false for wrong codes without
    /// revealing whether a record exists.
    public static func verify(passcode: String, against record: AppLockRecord?) -> Bool {
        guard let record, passcode.count == 4, passcode.allSatisfy(\.isNumber) else { return false }
        return digest(passcode: passcode, salt: record.salt) == record.hash
    }

    private static func baseQuery(service: String, key: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let group = accessGroup ?? Bundle.main.infoDictionary?["PlauselyKeychainAccessGroup"] as? String
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}
