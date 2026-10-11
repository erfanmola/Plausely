import Foundation
import Security

/// Small, nonsecret records shared by the app and its extensions through the
/// keychain. This is the fallback when the current signing team cannot use an
/// App Group container (for example, a free Apple ID development profile).
public enum SharedKeychainDataStore {
    public static var accessGroup: String? {
        Bundle.main.infoDictionary?["PlauselyKeychainAccessGroup"] as? String
    }

    public static func load(service: String, key: String, accessGroup: String? = accessGroup) -> Data? {
        var query = baseQuery(service: service, key: key, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public static func save(_ data: Data, service: String, key: String, accessGroup: String? = accessGroup) throws {
        let query = baseQuery(service: service, key: key, accessGroup: accessGroup)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    public static func remove(service: String, key: String, accessGroup: String? = accessGroup) throws {
        let status = SecItemDelete(baseQuery(service: service, key: key, accessGroup: accessGroup) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    public static func keys(service: String, accessGroup: String? = accessGroup) -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let rows = items as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func baseQuery(service: String, key: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
