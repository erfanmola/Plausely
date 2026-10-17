import Foundation

/// Shared watch bridge (Foundation only, no AnalyticsCore import).
/// One file compiled into both the iOS app and the watchOS app so the
/// WatchConnectivity contract has a single source of truth.
///
/// Transport: `WCSession.sendMessage(["op": ..., "payload": Data])` where
/// payload is the JSON-encoded request, and the reply is
/// `["payload": Data]` with the JSON-encoded response. Data values are
/// plist-safe for WatchConnectivity, and Codable keeps `nil` chart buckets.
public enum WatchOp: String, Sendable {
    case sites
    case overview
    case breakdown
}

/// Periods offered on watch. Raw values are stable wire strings; the iPhone
/// maps them onto `Period` (AnalyticsCore) — the watch never imports it.
public enum WatchPeriod: String, Codable, CaseIterable, Sendable {
    case realtime
    case today
    case last7Days
    case last28Days
    case last30Days
    case last12Months

    public var title: String {
        switch self {
        case .realtime: return "Realtime"
        case .today: return "Today"
        case .last7Days: return "Last 7 days"
        case .last28Days: return "Last 28 days"
        case .last30Days: return "Last 30 days"
        case .last12Months: return "Last 12 months"
        }
    }
}

/// Breakdown dimensions offered on watch (read-only summaries).
public enum WatchDimension: String, Codable, CaseIterable, Sendable {
    case sources
    case pages
    case countries
    case devices

    public var title: String {
        switch self {
        case .sources: return "Sources"
        case .pages: return "Pages"
        case .countries: return "Countries"
        case .devices: return "Devices"
        }
    }
}

public struct WatchSite: Codable, Hashable, Sendable, Identifiable {
    public let accountID: String // UUID string
    public let accountName: String // email or host
    public let domain: String
    public let teamID: String?
    public let role: String?

    public var id: String { accountID + "/" + domain }

    public init(accountID: String, accountName: String, domain: String, teamID: String? = nil, role: String? = nil) {
        self.accountID = accountID
        self.accountName = accountName
        self.domain = domain
        self.teamID = teamID
        self.role = role
    }
}

public struct WatchMetric: Codable, Hashable, Sendable {
    public let name: String
    public let displayValue: String
    public let changeText: String?

    public init(name: String, displayValue: String, changeText: String? = nil) {
        self.name = name
        self.displayValue = displayValue
        self.changeText = changeText
    }
}

public struct WatchOverviewRequest: Codable, Sendable {
    public let accountID: String
    public let domain: String
    public let period: WatchPeriod

    public init(accountID: String, domain: String, period: WatchPeriod) {
        self.accountID = accountID
        self.domain = domain
        self.period = period
    }
}

public struct WatchOverviewResponse: Codable, Sendable {
    public let domain: String
    public let periodTitle: String
    public let realtimeVisitors: Int?
    public let metrics: [WatchMetric]
    public let chartValues: [Double?]
    public let error: String?

    public init(
        domain: String,
        periodTitle: String,
        realtimeVisitors: Int? = nil,
        metrics: [WatchMetric] = [],
        chartValues: [Double?] = [],
        error: String? = nil
    ) {
        self.domain = domain
        self.periodTitle = periodTitle
        self.realtimeVisitors = realtimeVisitors
        self.metrics = metrics
        self.chartValues = chartValues
        self.error = error
    }

    public static func failure(domain: String, periodTitle: String, message: String) -> Self {
        Self(domain: domain, periodTitle: periodTitle, error: message)
    }
}

public struct WatchBreakdownRequest: Codable, Sendable {
    public let accountID: String
    public let domain: String
    public let period: WatchPeriod
    public let dimension: WatchDimension

    public init(accountID: String, domain: String, period: WatchPeriod, dimension: WatchDimension) {
        self.accountID = accountID
        self.domain = domain
        self.period = period
        self.dimension = dimension
    }
}

public struct WatchBreakdownRow: Codable, Hashable, Sendable {
    public let name: String
    public let valueText: String
    public let changeText: String?

    public init(name: String, valueText: String, changeText: String? = nil) {
        self.name = name
        self.valueText = valueText
        self.changeText = changeText
    }
}

public struct WatchBreakdownResponse: Codable, Sendable {
    public let domain: String
    public let dimension: WatchDimension
    public let rows: [WatchBreakdownRow]
    public let error: String?

    public init(domain: String, dimension: WatchDimension, rows: [WatchBreakdownRow] = [], error: String? = nil) {
        self.domain = domain
        self.dimension = dimension
        self.rows = rows
        self.error = error
    }
}

public struct WatchSitesResponse: Codable, Sendable {
    public let sites: [WatchSite]
    public let error: String?

    public init(sites: [WatchSite] = [], error: String? = nil) {
        self.sites = sites
        self.error = error
    }
}

/// Deterministic mock payloads for watch previews and the
/// `-plausely-mock` watch launch path (no phone needed).
public enum WatchMock {
    public static let sites = [
        WatchSite(accountID: "mock-account", accountName: "owner@example.com", domain: "alpha-1.example.com", teamID: "team-alpha", role: "owner"),
        WatchSite(accountID: "mock-account", accountName: "owner@example.com", domain: "beta-1.example.org", teamID: "team-beta", role: "viewer"),
    ]

    public static func overview(domain: String, period: WatchPeriod) -> WatchOverviewResponse {
        WatchOverviewResponse(
            domain: domain,
            periodTitle: period.title,
            realtimeVisitors: 42,
            metrics: [
                WatchMetric(name: "Unique visitors", displayValue: "12,480", changeText: "+8%"),
                WatchMetric(name: "Total visits", displayValue: "15,204", changeText: "+5%"),
                WatchMetric(name: "Total pageviews", displayValue: "28,710", changeText: "+11%"),
                WatchMetric(name: "Bounce rate", displayValue: "38%", changeText: "-2%"),
                WatchMetric(name: "Visit duration", displayValue: "2m 14s"),
            ],
            chartValues: [2, 3, 2, 5, 4, 7, 6, 8, 7, 9, 11, 10]
        )
    }

    public static func breakdown(domain: String, dimension: WatchDimension) -> WatchBreakdownResponse {
        let rows: [WatchBreakdownRow]
        switch dimension {
        case .sources:
            rows = [
                WatchBreakdownRow(name: "Google", valueText: "8,204", changeText: "+6%"),
                WatchBreakdownRow(name: "Direct", valueText: "3,102", changeText: "+2%"),
                WatchBreakdownRow(name: "GitHub", valueText: "812"),
            ]
        case .pages:
            rows = [
                WatchBreakdownRow(name: "/", valueText: "9,410"),
                WatchBreakdownRow(name: "/blog", valueText: "2,870", changeText: "+14%"),
                WatchBreakdownRow(name: "/pricing", valueText: "1,204"),
            ]
        case .countries:
            rows = [
                WatchBreakdownRow(name: "United States", valueText: "5,120"),
                WatchBreakdownRow(name: "Germany", valueText: "2,340"),
                WatchBreakdownRow(name: "United Kingdom", valueText: "1,102"),
            ]
        case .devices:
            rows = [
                WatchBreakdownRow(name: "Mac", valueText: "6,480"),
                WatchBreakdownRow(name: "iPhone", valueText: "4,102", changeText: "+9%"),
                WatchBreakdownRow(name: "Windows", valueText: "1,898"),
            ]
        }
        return WatchBreakdownResponse(domain: domain, dimension: dimension, rows: rows)
    }
}
