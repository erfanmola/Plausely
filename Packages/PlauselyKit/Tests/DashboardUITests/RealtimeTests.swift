import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

private actor CallLog {
    var calls: [(AccountID, SiteID)] = []
    var fail = false
    /// Manual fetch gate: each fetch blocks until released, so polling
    /// loops stay fully deterministic with no sleep-based races.
    var waiters: [CheckedContinuation<Void, Never>] = []
    var gated = false
    func record(account: AccountID, site: SiteID) async throws -> Int {
        if gated {
            await withCheckedContinuation { waiters.append($0) }
        }
        calls.append((account, site))
        if fail { throw StubError.unavailable }
        return calls.count * 10
    }

    func callCount() -> Int { calls.count }
    func setFail(_ value: Bool) { fail = value }
    func setGated(_ value: Bool) { gated = value }
    func releaseOne() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    func waiterCount() -> Int { waiters.count }
}

private enum StubError: Error {
    case unavailable
}

@Suite("realtime headcount (LIVE-01)")
@MainActor
struct RealtimeTests {
    @Test("polls on start, restarts on identity change, stops on demand")
    func lifecycle() async throws {
        let log = CallLog()
        let loader: RealtimeModel.CountLoader = { account, site in
            try await log.record(account: account, site: site)
        }
        let account = AccountID()
        let site = SiteID(domain: "shop.example")
        let model = RealtimeModel(pollInterval: 0.02)

        model.start(account: account, site: site, loader: loader)
        // First fetch lands without waiting a full interval.
        let deadline = Date().addingTimeInterval(2)
        while model.count == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.count != nil)
        #expect(model.errorMessage == nil)

        // Same identity restarts never spawn a second loop. Fresh gated
        // model: every fetch blocks until released, so loop counting is
        // exact with no sleep-based races.
        let log2 = CallLog()
        await log2.setGated(true)
        let loader2: RealtimeModel.CountLoader = { account, site in
            try await log2.record(account: account, site: site)
        }
        let model2 = RealtimeModel(pollInterval: 0.02)
        model2.start(account: account, site: site, loader: loader2)
        while await log2.waiterCount() == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        model2.start(account: account, site: site, loader: loader2)
        let calm = Date().addingTimeInterval(0.2)
        while Date() < calm {
            #expect(await log2.waiterCount() <= 1)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await log2.releaseOne()
        while await log2.callCount() == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await log2.callCount() == 1)
        #expect(model2.count == 10)
        model2.stop()

        // A new site resets the count so headcounts never cross sites.
        let other = SiteID(domain: "blog.example")
        model.start(account: account, site: other, loader: loader)
        #expect(model.count == nil)
        while model.count == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.errorMessage == nil)

        model.stop()
        let frozen = await log.callCount()
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(await log.callCount() == frozen)
    }

    @Test("failed polls keep the last count with an explicit error")
    func failureKeepsStale() async throws {
        let log = CallLog()
        let loader: RealtimeModel.CountLoader = { account, site in
            try await log.record(account: account, site: site)
        }
        let model = RealtimeModel(pollInterval: 0.02)
        model.start(account: AccountID(), site: SiteID(domain: "shop.example"), loader: loader)
        let deadline = Date().addingTimeInterval(2)
        while model.count == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.count == 10)
        await log.setFail(true)
        while model.errorMessage == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.count == 10)
        #expect(model.errorMessage != nil)
        model.stop()
    }

    @Test("realtime ticks reach the armed refresh")
    func tickGating() async throws {
        var ticks = 0
        let model = RealtimeModel(pollInterval: 0.02)
        model.onTick = { ticks += 1 }
        model.start(account: AccountID(), site: SiteID(domain: "shop.example")) { _, _ in 1 }
        let deadline = Date().addingTimeInterval(2)
        while ticks < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(ticks >= 2)
        model.stop()
    }
}
