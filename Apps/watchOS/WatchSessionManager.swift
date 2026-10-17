import Foundation
import WatchConnectivity

/// Phone link for the watch app. Sends Codable requests over
/// WatchConnectivity and decodes the iPhone's replies.
///
/// The watch never holds secrets or talks to Plausible directly: the iPhone
/// `WatchLinkResponder` (Apps/iOS) runs every query through the productized
/// `LiveHub` and returns pre-formatted display strings, so numbers match the
/// app exactly. `-plausely-mock` serves `WatchMock` payloads with no phone.
@MainActor
@Observable
final class WatchSessionManager: NSObject {
    var sites: [WatchSite] = []
    var sitesError: String?
    var sitesLoading = false
    var reachable: Bool = false

    static var isMock: Bool {
        CommandLine.arguments.contains("-plausely-mock")
    }

    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            reachable = session.isReachable
        }
        if Self.isMock {
            sites = WatchMock.sites
        }
    }

    // MARK: - Requests

    func refreshSites() async {
        if Self.isMock {
            sites = WatchMock.sites
            sitesError = nil
            return
        }
        sitesLoading = true
        defer { sitesLoading = false }
        do {
            let response: WatchSitesResponse = try await send(op: .sites, request: WatchPing())
            sites = response.sites
            sitesError = response.error ?? (response.sites.isEmpty ? "No sites yet. Open Plausely on iPhone and sign in." : nil)
        } catch {
            sitesError = Self.friendlyError(error)
        }
    }

    func overview(site: WatchSite, period: WatchPeriod) async -> WatchOverviewResponse {
        if Self.isMock { return WatchMock.overview(domain: site.domain, period: period) }
        do {
            let response: WatchOverviewResponse = try await send(
                op: .overview,
                request: WatchOverviewRequest(accountID: site.accountID, domain: site.domain, period: period)
            )
            return response
        } catch {
            return WatchOverviewResponse.failure(domain: site.domain, periodTitle: period.title, message: Self.friendlyError(error))
        }
    }

    func breakdown(site: WatchSite, period: WatchPeriod, dimension: WatchDimension) async -> WatchBreakdownResponse {
        if Self.isMock { return WatchMock.breakdown(domain: site.domain, dimension: dimension) }
        do {
            let response: WatchBreakdownResponse = try await send(
                op: .breakdown,
                request: WatchBreakdownRequest(accountID: site.accountID, domain: site.domain, period: period, dimension: dimension)
            )
            return response
        } catch {
            return WatchBreakdownResponse(domain: site.domain, dimension: dimension, error: Self.friendlyError(error))
        }
    }

    // MARK: - Transport

    private struct WatchPing: Codable, Sendable {}

    nonisolated private func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        op: WatchOp,
        request: Request
    ) async throws -> Response {
        guard WCSession.isSupported() else { throw WatchLinkError.noPhone }
        let session = WCSession.default
        guard session.isReachable else { throw WatchLinkError.unreachable }
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(["op": op.rawValue, "payload": payload]) { reply in
                do {
                    guard let data = reply["payload"] as? Data else { throw WatchLinkError.badReply }
                    continuation.resume(returning: try JSONDecoder().decode(Response.self, from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            } errorHandler: { error in
                continuation.resume(throwing: error)
            }
        }
    }

    private static func friendlyError(_ error: Error) -> String {
        if let link = error as? WatchLinkError { return link.message }
        let ns = error as NSError
        // WatchConnectivity not-reachable surfaces as WCErrorDomain Code=65.
        if ns.domain == "WCErrorDomain" {
            return "Open Plausely on iPhone — the watch needs the phone nearby to load analytics."
        }
        return "Couldn't load analytics. Open Plausely on iPhone and try again."
    }
}

enum WatchLinkError: Error {
    case noPhone
    case unreachable
    case badReply

    var message: String {
        switch self {
        case .noPhone:
            return "This watch can't reach its iPhone."
        case .unreachable:
            return "Open Plausely on iPhone — the watch needs the phone nearby to load analytics."
        case .badReply:
            return "The iPhone sent an unreadable reply. Try again."
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let isReachable = session.isReachable
        Task { @MainActor in
            reachable = isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in
            reachable = isReachable
        }
    }
}
