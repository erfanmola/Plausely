import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

private actor CallLog {
    var calls: [(AccountID, SiteID)] = []
    var fail = false
    func record(account: AccountID, site: SiteID) throws -> Int {
        calls.append((account, site))
        if fail { throw StubError.unavailable }
        return calls.count * 10
    }

    func callCount() -> Int { calls.count }
    func setFail(_ value: Bool) { fail = value }
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
        #expect(model.count == 10)
        #expect(model.errorMessage == nil)

        // Same identity while running is a no-op for restarts; the loop
        // keeps polling on its cadence.
        let before = await log.callCount()
        model.start(account: account, site: site, loader: loader)
        #expect(await log.callCount() == before)
        while await log.callCount() < before + 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(model.count == (before + 2) * 10)

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
