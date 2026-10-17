import AnalyticsCore
import Foundation
import WatchConnectivity

/// iPhone side of the watch bridge. Answers WatchConnectivity messages from
/// the companion watch app using the shared `LiveHub`, so the watch stays a
/// thin client: secrets never leave the phone, Bluetooth works without the
/// watch having network, and formatting matches the app exactly.
///
/// Wire-up: `LiveRootView` hands its hub over and activates once. The watch
/// app has its own `-plausely-mock` path and never calls the phone in
/// previews. All work is isolated to Sendable captures (`hub` is an actor,
/// payloads are value types); the reply closure crosses into the Task via an
/// explicit unchecked box because WatchConnectivity guarantees it is safe to
/// call exactly once from any queue.
final class WatchLinkResponder: NSObject, WCSessionDelegate {
    private let hub: LiveHub

    init(hub: LiveHub) {
        self.hub = hub
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after watch switches, per WatchConnectivity docs.
        session.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard
            let opRaw = message["op"] as? String,
            let op = WatchOp(rawValue: opRaw),
            let payload = message["payload"] as? Data
        else {
            Self.reply(
                WatchOverviewResponse.failure(domain: "", periodTitle: "", message: "Unsupported watch request."),
                replyHandler: replyHandler
            )
            return
        }
        struct ReplyBox: @unchecked Sendable { let fn: ([String: Any]) -> Void }
        let box = ReplyBox(fn: replyHandler)
        let hub = self.hub
        Task {
            switch op {
            case .sites:
                await Self.replySites(hub: hub, replyHandler: box.fn)
            case .overview:
                await Self.replyOverview(hub: hub, payload: payload, replyHandler: box.fn)
            case .breakdown:
                await Self.replyBreakdown(hub: hub, payload: payload, replyHandler: box.fn)
            }
        }
    }

    // MARK: - Handlers

    private static func replySites(hub: LiveHub, replyHandler: @escaping ([String: Any]) -> Void) async {
        let accounts = await hub.accountRefs()
        var sites: [WatchSite] = []
        for account in accounts {
            let display = account.email ?? account.baseURL.host ?? account.baseURL.absoluteString
            do {
                let discovered = try await hub.sites(for: account)
                for site in discovered {
                    sites.append(WatchSite(
                        accountID: account.id.rawValue.uuidString,
                        accountName: display,
                        domain: site.domain,
                        teamID: site.teamID,
                        role: site.role
                    ))
                }
            } catch {
                continue
            }
        }
        reply(WatchSitesResponse(sites: sites.sorted { $0.domain < $1.domain }), replyHandler: replyHandler)
    }

    private static func replyOverview(hub: LiveHub, payload: Data, replyHandler: @escaping ([String: Any]) -> Void) async {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(WatchOverviewRequest.self, from: payload),
              let uuid = UUID(uuidString: request.accountID)
        else {
            reply(WatchOverviewResponse.failure(domain: "", periodTitle: "", message: "Bad overview request."), replyHandler: replyHandler)
            return
        }
        let accountID = AccountID(rawValue: uuid)
        let formatter = MetricFormatter()
        do {
            let zone = await hub.timeZone(account: accountID, domain: request.domain) ?? TimeZone(identifier: "UTC")!
            let team = await teamID(hub: hub, accountID: accountID, domain: request.domain)
            let period = Self.period(request.period)
            let interval: ChartInterval = period == .day ? .hour : .day
            let query = DashboardQuery(
                accountID: accountID,
                siteID: SiteID(domain: request.domain, teamID: team),
                period: period,
                periodDate: period == .day ? Date() : nil,
                comparison: .off,
                interval: interval,
                selectedMetric: .visitors,
                timeZone: zone
            )
            let now = Date()
            async let realtimeCount = hub.currentVisitors(accountID: accountID, domain: request.domain)
            async let overviewEnvelope = hub.overview(query, today: now)
            async let seriesEnvelope = hub.series(query, today: now)
            let realtime = try? await realtimeCount
            let overview = try await overviewEnvelope
            let series = try await seriesEnvelope
            let metrics = overview.value.stats.prefix(6).map { stat in
                WatchMetric(
                    name: stat.name,
                    displayValue: formatter.string(for: stat.value, as: stat.metric),
                    changeText: stat.change.map { Self.signedPercent($0) }
                )
            }
            let response = WatchOverviewResponse(
                domain: request.domain,
                periodTitle: request.period.title,
                realtimeVisitors: realtime,
                metrics: Array(metrics),
                chartValues: series.value.plot.map(Self.doubleValue)
            )
            reply(response, replyHandler: replyHandler)
        } catch {
            reply(
                WatchOverviewResponse.failure(domain: request.domain, periodTitle: request.period.title, message: "Couldn't load analytics. Open Plausely on iPhone."),
                replyHandler: replyHandler
            )
        }
    }

    private static func replyBreakdown(hub: LiveHub, payload: Data, replyHandler: @escaping ([String: Any]) -> Void) async {
        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(WatchBreakdownRequest.self, from: payload),
              let uuid = UUID(uuidString: request.accountID)
        else {
            reply(WatchBreakdownResponse(domain: "", dimension: .sources, error: "Bad breakdown request."), replyHandler: replyHandler)
            return
        }
        let accountID = AccountID(rawValue: uuid)
        let formatter = MetricFormatter()
        do {
            let zone = await hub.timeZone(account: accountID, domain: request.domain) ?? TimeZone(identifier: "UTC")!
            let team = await teamID(hub: hub, accountID: accountID, domain: request.domain)
            let period = Self.period(request.period)
            let query = DashboardQuery(
                accountID: accountID,
                siteID: SiteID(domain: request.domain, teamID: team),
                period: period,
                periodDate: period == .day ? Date() : nil,
                comparison: .off,
                interval: period == .day ? .hour : .day,
                selectedMetric: .visitors,
                timeZone: zone
            )
            let page = try await hub.breakdown(
                BreakdownRequest(query: query, kind: Self.kind(request.dimension), pagination: Pagination(limit: 10, page: 1)),
                today: Date()
            )
            let rows = page.value.rows.prefix(10).map { row -> WatchBreakdownRow in
                let primary = row.metrics[.visitors] ?? row.metrics[.visits] ?? row.metrics[.pageviews] ?? row.metrics.first?.value
                let metric: MetricID = row.metrics[.visitors] != nil ? .visitors : (row.metrics[.visits] != nil ? .visits : .pageviews)
                let valueText = primary.map { formatter.string(for: $0, as: metric) } ?? "–"
                let change = row.metrics[.visitors].flatMap { _ in row.change[.visitors] }
                    ?? row.metrics[.visits].flatMap { _ in row.change[.visits] }
                    ?? row.change[.pageviews]
                return WatchBreakdownRow(
                    name: row.name,
                    valueText: valueText,
                    changeText: change.map { $0.map(Self.signedPercent) ?? nil } ?? nil
                )
            }
            reply(WatchBreakdownResponse(domain: request.domain, dimension: request.dimension, rows: Array(rows)), replyHandler: replyHandler)
        } catch {
            reply(
                WatchBreakdownResponse(domain: request.domain, dimension: request.dimension, error: "Couldn't load this breakdown. Open Plausely on iPhone."),
                replyHandler: replyHandler
            )
        }
    }

    // MARK: - Helpers

    private static func reply<T: Encodable>(_ value: T, replyHandler: @escaping ([String: Any]) -> Void) {
        let payload = (try? JSONEncoder().encode(value)) ?? Data()
        replyHandler(["payload": payload])
    }

    private static func teamID(hub: LiveHub, accountID: AccountID, domain: String) async -> String? {
        // Sites discovery already ran for the picker; reuse it cheaply.
        let accounts = await hub.accountRefs()
        guard let account = accounts.first(where: { $0.id == accountID }) else { return nil }
        return (try? await hub.sites(for: account))?.first(where: { $0.domain == domain })?.teamID
    }

    private static func period(_ period: WatchPeriod) -> Period {
        switch period {
        case .realtime: return .realtime
        case .today: return .day
        case .last7Days: return .days7
        case .last28Days: return .days28
        case .last30Days: return .days30
        case .last12Months: return .months12
        }
    }

    private static func kind(_ dimension: WatchDimension) -> ReportKind {
        switch dimension {
        case .sources: return .sources
        case .pages: return .pages
        case .countries: return .countries
        case .devices: return .operatingSystems
        }
    }

    private static func doubleValue(_ value: MetricValue?) -> Double? {
        switch value {
        case .count(let number): return Double(number)
        case .decimal(let number): return NSDecimalNumber(decimal: number).doubleValue
        case .unavailable, nil: return nil
        }
    }

    private static func signedPercent(_ change: Int) -> String {
        change >= 0 ? "+\(change)%" : "\(change)%"
    }
}
