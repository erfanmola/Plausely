import AnalyticsCore
import Foundation
import Security

/// Keychain-backed `CredentialStore`. Secrets use generic-password items
/// scoped by service + account UUID, `afterFirstUnlockThisDeviceOnly`
/// (no sync, no backup), matching the foreground-only client. No secret ever
/// touches UserDefaults, files, logs, or fixtures.
///
/// NOTE: the sandboxed macOS app target needs a keychain-access-groups
/// entitlement plus a distribution signing identity before this store can
/// operate in a signed release build (phase-10 distribution item). The API,
/// isolation, and removal semantics below are final and unit-tested.
public struct KeychainCredentialStore: CredentialStore, Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "ir.developex.Plausely.session", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load(for account: AccountID) async throws -> SessionCredential? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var query = base
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        // Migrate an existing app-private credential into the shared group on
        // first use. Extensions never fall back to their own private group.
        if status == errSecItemNotFound, accessGroup != nil {
            item = nil
            status = SecItemCopyMatching(base as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let credential = try? JSONDecoder().decode(SessionCredential.self, from: data) {
                try? await save(credential, for: account)
                return credential
            }
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStoreError.keychain(status)
        }
        guard let credential = try? JSONDecoder().decode(SessionCredential.self, from: data) else {
            throw CredentialStoreError.encoding
        }
        return credential
    }

    public func save(_ credential: SessionCredential, for account: AccountID) async throws {
        guard let data = try? JSONEncoder().encode(credential) else {
            throw CredentialStoreError.encoding
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue.uuidString,
        ]
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let accessGroup { attributes[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
    }

    public func remove(for account: AccountID) async throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue.uuidString,
        ]
        var queries = [base]
        if let accessGroup {
            var shared = base
            shared[kSecAttrAccessGroup as String] = accessGroup
            queries.insert(shared, at: 0)
        }
        for query in queries {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
        }
    }
}
