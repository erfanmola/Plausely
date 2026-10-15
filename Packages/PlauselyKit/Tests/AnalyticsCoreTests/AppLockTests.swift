import Foundation
import Testing

@testable import AnalyticsCore

@Suite("app lock store")
struct AppLockTests {
    private func isolated() -> (service: String, key: String) {
        ("ir.developex.Plausely.test-lock-\(UUID().uuidString)", "config")
    }

    @Test("digest is deterministic and salt-sensitive")
    func digest() {
        let salt = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        #expect(AppLockStore.digest(passcode: "1934", salt: salt) == AppLockStore.digest(passcode: "1934", salt: salt))
        #expect(AppLockStore.digest(passcode: "1934", salt: salt) != AppLockStore.digest(passcode: "1935", salt: salt))
        #expect(AppLockStore.digest(passcode: "1934", salt: salt) != AppLockStore.digest(passcode: "1934", salt: Data(repeating: 9, count: 16)))
        #expect(AppLockStore.randomSalt().count == 16)
        #expect(AppLockStore.randomSalt() != AppLockStore.randomSalt())
    }

    @Test("verification accepts the code and rejects everything else")
    func verify() {
        let salt = Data(repeating: 7, count: 16)
        let record = AppLockRecord(
            salt: salt,
            hash: AppLockStore.digest(passcode: "1934", salt: salt),
            biometricEnabled: false
        )
        #expect(AppLockStore.verify(passcode: "1934", against: record))
        #expect(!AppLockStore.verify(passcode: "0000", against: record))
        #expect(!AppLockStore.verify(passcode: "193", against: record))
        #expect(!AppLockStore.verify(passcode: "19344", against: record))
        #expect(!AppLockStore.verify(passcode: "abcd", against: record))
        #expect(!AppLockStore.verify(passcode: "1934", against: nil))
    }

    @Test("records persist, replace, and clear in isolation")
    func persistence() throws {
        let (service, key) = isolated()
        #expect(AppLockStore.load(service: service, key: key) == nil)
        let salt = Data(repeating: 3, count: 16)
        try AppLockStore.save(
            AppLockRecord(salt: salt, hash: AppLockStore.digest(passcode: "0000", salt: salt), biometricEnabled: true),
            service: service, key: key
        )
        let loaded = try #require(AppLockStore.load(service: service, key: key))
        #expect(loaded.biometricEnabled)
        #expect(AppLockStore.verify(passcode: "0000", against: loaded))
        try AppLockStore.save(
            AppLockRecord(salt: salt, hash: AppLockStore.digest(passcode: "0000", salt: salt), biometricEnabled: false),
            service: service, key: key
        )
        #expect(AppLockStore.load(service: service, key: key)?.biometricEnabled == false)
        try AppLockStore.remove(service: service, key: key)
        #expect(AppLockStore.load(service: service, key: key) == nil)
    }

    @Test("tampered hashes never verify")
    func tamper() {
        let salt = Data(repeating: 5, count: 16)
        let record = AppLockRecord(salt: salt, hash: Data(repeating: 0, count: 32), biometricEnabled: false)
        #expect(!AppLockStore.verify(passcode: "1934", against: record))
    }
}
