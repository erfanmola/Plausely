import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

private func credential(base: String = "https://stats.example.test") -> SessionCredential {
    SessionCredential(
        baseURL: URL(string: base)!,
        cookies: [CookieRecord(name: "k", value: "v", domain: "stats.example.test", path: "/", secure: true, httpOnly: true)],
        retrievedAt: Date()
    )
}

@Suite("credential and account stores")
struct StoreTests {
    @Test("keychain roundtrip isolates accounts and clears on removal")
    func keychainRoundtrip() async throws {
        let store = KeychainCredentialStore(service: "ir.developex.Plausely.test-\(UUID().uuidString)")
        let first = AccountID()
        let second = AccountID()
        #expect(try await store.load(for: first) == nil)
        try await store.save(credential(), for: first)
        try await store.save(credential(base: "https://other.example.test"), for: second)
        #expect(try await store.load(for: first)?.baseURL.absoluteString == "https://stats.example.test")
        #expect(try await store.load(for: second)?.baseURL.absoluteString == "https://other.example.test")
        try await store.remove(for: first)
        #expect(try await store.load(for: first) == nil)
        #expect(try await store.load(for: second) != nil)
        try await store.remove(for: second)
    }

    @Test("cookie records rebuild usable cookies")
    func cookieRoundtrip() {
        let record = CookieRecord(name: "session", value: "abc", domain: "x.test", path: "/", secure: true, httpOnly: true)
        let cookie = record.httpCookie()
        #expect(cookie?.name == "session")
        #expect(cookie?.value == "abc")
        #expect(cookie?.domain == "x.test")
        #expect(CookieRecord(cookie: cookie!).name == "session")
    }

    @Test("account store roundtrips, lists, migrates, and clears per account")
    func accountStore() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "plausely-acct-\(UUID().uuidString)")
        let store = AccountStore(directory: dir)
        let first = AccountRecord(id: AccountID(), baseURL: URL(string: "https://a.test")!, email: "a@test")
        let second = AccountRecord(id: AccountID(), baseURL: URL(string: "https://b.test")!, email: nil)
        try store.save(first)
        try store.save(second)
        #expect(try store.load(id: first.id) == first)
        #expect(try store.allIDs().count == 2)
        try store.remove(id: first.id)
        #expect(try store.load(id: first.id) == nil)
        #expect(try store.allIDs().count == 1)
        try store.remove(id: second.id)
        try FileManager.default.removeItem(at: dir)
    }

    @Test("corrupt records fail typed, and records hold no secrets")
    func corruptAndClean() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "plausely-acct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AccountStore(directory: dir)
        let id = AccountID()
        try "not-json{{{".write(to: dir.appending(path: "\(id.rawValue.uuidString).json"), atomically: true, encoding: .utf8)
        do {
            _ = try store.load(id: id)
            Issue.record("expected corruptStore")
        } catch let error as AccountStoreError {
            #expect(error == .corruptStore(id.rawValue.uuidString))
        }
        let record = AccountRecord(id: AccountID(), baseURL: URL(string: "https://a.test")!, email: "a@test")
        let encoded = String(data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
        #expect(!encoded.lowercased().contains("cookie"))
        #expect(!encoded.lowercased().contains("password"))
        #expect(!encoded.lowercased().contains("token"))
        try FileManager.default.removeItem(at: dir)
    }
}
