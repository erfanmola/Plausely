import Testing
@testable import AnalyticsCore
@testable import PlausibleClient
import Foundation

private struct FakeBridge: WebLoginBridge {
    let cookies: [HTTPCookie]
    final class Counter: @unchecked Sendable {
        var calls = 0; var maxActive = 0; var active = 0
    }
    let counter = Counter()
    func loginCookies(email: String, password: String) async throws -> [HTTPCookie] {
        counter.calls += 1
        counter.active += 1
        counter.maxActive = max(counter.maxActive, counter.active)
        defer { counter.active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return cookies
    }
}

private struct FakeCredentialStore: CredentialStore {
    final class Box: @unchecked Sendable { var saved: [String: SessionCredential] = [:] }
    let box = Box()
    func load(for account: AccountID) async throws -> SessionCredential? {
        box.saved[account.rawValue.uuidString]
    }
    func save(_ credential: SessionCredential, for account: AccountID) async throws {
        box.saved[account.rawValue.uuidString] = credential
    }
    func remove(for account: AccountID) async throws {
        box.saved.removeValue(forKey: account.rawValue.uuidString)
    }
}

private struct FakeTransport: HTTPTransport {
    final class Box: @unchecked Sendable { var requests: [URLRequest] = [] }
    let box = Box()
    func send(_ request: URLRequest, expecting: ContentKind = .json) async throws -> (Data, HTTPURLResponse) {
        box.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}

private func sessionCookie() -> HTTPCookie {
    HTTPCookie(properties: [
        .name: "k", .value: "v", .domain: "stats.example.test",
        .path: "/", .secure: "TRUE",
    ])!
}

@Suite("session coordinator")
struct SessionCoordinatorTests {
    @Test("login persists secret and record; headers carry cookies")
    func loginFlow() async throws {
        let bridge = FakeBridge(cookies: [sessionCookie()])
        let creds = FakeCredentialStore()
        let dir = FileManager.default.temporaryDirectory.appending(path: "plausely-sess-\(UUID().uuidString)")
        let accounts = AccountStore(directory: dir)
        let coordinator = SessionCoordinator(bridge: bridge, credentials: creds, accounts: accounts, transport: FakeTransport())
        let account = AccountID()
        let base = URL(string: "https://stats.example.test")!
        _ = try await coordinator.login(account: account, baseURL: base, email: "a@test", password: "pw")
        #expect(bridge.counter.calls == 1)
        #expect(try await creds.load(for: account) != nil)
        #expect(try accounts.load(id: account)?.email == "a@test")
        let headers = try await coordinator.headers(for: URL(string: "https://stats.example.test/api/x")!, account: account)
        #expect((headers["Cookie"] ?? "").contains("k=v"))
        #expect(await coordinator.isValid(account: account))
        try FileManager.default.removeItem(at: dir)
    }

    @Test("login-required marks the session dead; logout clears the secret")
    func invalidationAndLogout() async throws {
        let bridge = FakeBridge(cookies: [sessionCookie()])
        let creds = FakeCredentialStore()
        let dir = FileManager.default.temporaryDirectory.appending(path: "plausely-sess-\(UUID().uuidString)")
        let accounts = AccountStore(directory: dir)
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(bridge: bridge, credentials: creds, accounts: accounts, transport: transport)
        let account = AccountID()
        let base = URL(string: "https://stats.example.test")!
        _ = try await coordinator.login(account: account, baseURL: base, email: "a@test", password: "pw")
        await coordinator.noteLoginRequired(account: account)
        #expect(await coordinator.isValid(account: account) == false)
        try await coordinator.logout(account: account)
        #expect(try await creds.load(for: account) == nil)
        #expect(try accounts.load(id: account) != nil)
        #expect(transport.box.requests.first?.url?.path() == "/logout")
        try FileManager.default.removeItem(at: dir)
    }

    @Test("accounts are isolated and delete fully")
    func isolation() async throws {
        let bridge = FakeBridge(cookies: [sessionCookie()])
        let creds = FakeCredentialStore()
        let dir = FileManager.default.temporaryDirectory.appending(path: "plausely-sess-\(UUID().uuidString)")
        let accounts = AccountStore(directory: dir)
        let coordinator = SessionCoordinator(bridge: bridge, credentials: creds, accounts: accounts, transport: FakeTransport())
        let first = AccountID()
        let second = AccountID()
        let base = URL(string: "https://stats.example.test")!
        _ = try await coordinator.login(account: first, baseURL: base, email: "a@test", password: "pw")
        #expect(try await creds.load(for: second) == nil)
        try await coordinator.deleteAccount(account: first)
        #expect(try await creds.load(for: first) == nil)
        #expect(try accounts.load(id: first) == nil)
        try FileManager.default.removeItem(at: dir)
    }

    @Test("concurrent logins coalesce onto one bridge login")
    func serialization() async throws {
        let bridge = FakeBridge(cookies: [sessionCookie()])
        let coordinator = SessionCoordinator(
            bridge: bridge, credentials: FakeCredentialStore(),
            accounts: AccountStore(directory: FileManager.default.temporaryDirectory.appending(path: "plausely-sess-\(UUID().uuidString)")),
            transport: FakeTransport()
        )
        let account = AccountID()
        let base = URL(string: "https://stats.example.test")!
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await coordinator.login(account: account, baseURL: base, email: "a@test", password: "pw") }
            }
            try await group.waitForAll()
        }
        #expect(bridge.counter.calls == 1)
        #expect(bridge.counter.maxActive == 1)
    }
}
