import AnalyticsCore
import Foundation
import SwiftSoup

/// Decoded dashboard bootstrap for one site (`#stats-react-container`
/// on `GET /:domain`). Field set pinned to CE 3.2.1; unknown required
/// layout becomes a typed failure, never guessed defaults.
public struct BootstrapSnapshot: Equatable, Sendable {
    public let domain: String
    public let utcOffsetSeconds: Int
    public let hasGoals: Bool
    public let hasProps: Bool
    public let statsBegin: String
    public let nativeStatsBegin: String
    public let intervals: IntervalPolicy
    public let segmentCount: Int
    public let currentUserRole: String
    public let teamIdentifier: String?
    public let funnelsAvailable: Bool
    public let propsAvailable: Bool
    public let siteSegmentsAvailable: Bool
    public let isConsolidatedView: Bool
}

public enum BootstrapError: Error, Equatable {
    case unknownLayout
    case missingAttribute(String)
    case malformedAttribute(String)
}

/// Structured decoder for the CE 3.2.1 bootstrap container. Uses a real HTML
/// parser (SwiftSoup); regex is never used on markup.
public enum CE321BootstrapDecoder {
    public static func decode(html: String) throws -> BootstrapSnapshot {
        let document = try SwiftSoup.parse(html)
        guard let container = try document.select("#stats-react-container").first() else {
            throw BootstrapError.unknownLayout
        }
        func attr(_ name: String) throws -> String {
            let value = try container.attr("data-\(name)")
            guard !value.isEmpty else { throw BootstrapError.missingAttribute(name) }
            return value
        }
        func flag(_ name: String) throws -> Bool {
            switch try attr(name) {
            case "true": return true
            case "false": return false
            default: throw BootstrapError.malformedAttribute(name)
            }
        }
        let intervalsJSON = try attr("valid-intervals-by-period")
        guard let intervalsData = intervalsJSON.data(using: .utf8),
              let rawMap = try? JSONSerialization.jsonObject(with: intervalsData) as? [String: [String]] else {
            throw BootstrapError.malformedAttribute("valid-intervals-by-period")
        }
        var validByPeriod: [String: [ChartInterval]] = [:]
        for (period, names) in rawMap {
            validByPeriod[period] = try names.map { name in
                guard let interval = ChartInterval(rawValue: name) else {
                    throw BootstrapError.malformedAttribute("valid-intervals-by-period.\(period).\(name)")
                }
                return interval
            }
        }
        let segmentsJSON = try attr("segments")
        let segmentCount: Int
        if segmentsJSON == "[]" {
            segmentCount = 0
        } else if let data = segmentsJSON.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            segmentCount = array.count
        } else {
            throw BootstrapError.malformedAttribute("segments")
        }
        let teamID = try? container.attr("data-team-identifier")
        return BootstrapSnapshot(
            domain: try attr("domain"),
            utcOffsetSeconds: try Int(attr("offset")).unwrap(or: .malformedAttribute("offset")),
            hasGoals: try flag("has-goals"),
            hasProps: try flag("has-props"),
            statsBegin: try attr("stats-begin"),
            nativeStatsBegin: try attr("native-stats-begin"),
            intervals: IntervalPolicy(validByPeriod: validByPeriod),
            segmentCount: segmentCount,
            currentUserRole: try attr("current-user-role"),
            teamIdentifier: (teamID?.isEmpty == false) ? teamID : nil,
            funnelsAvailable: try flag("funnels-available"),
            propsAvailable: try flag("props-available"),
            siteSegmentsAvailable: try flag("site-segments-available"),
            isConsolidatedView: try flag("is-consolidated-view")
        )
    }

    /// IANA timezone from the site settings page (`select#site_timezone >
    /// option[selected]`). Nil means unresolved — the caller must carry
    /// offset-only as unverified, never substitute the device timezone.
    public static func timezone(html: String) -> TimeZone? {
        guard let document = try? SwiftSoup.parse(html),
              let selected = try? document.select("#site_timezone option[selected]").first(),
              let value = try? selected.attr("value"),
              !value.isEmpty else { return nil }
        return TimeZone(identifier: value)
    }

    /// Locked shared-link segment id from the dashboard container
    /// (`data-limited-to-segment-id`, upstream stats.html.heex:55). Nil
    /// means unlocked. Password-protected links render no container, so
    /// they surface as unknown-layout upstream, never as unlocked.
    public static func limitedSegmentID(html: String) -> Int? {
        guard let document = try? SwiftSoup.parse(html),
              let container = try? document.select("#stats-react-container").first(),
              let raw = try? container.attr("data-limited-to-segment-id"),
              !raw.isEmpty else { return nil }
        return Int(raw)
    }

    /// Domains from the `/sites` overview page (`[data-domain]`). Sorted and
    /// deduplicated; the page is the complete enumeration (the 9-row
    /// `/api/sites` endpoint is never used alone).
    public static func siteDomains(html: String) throws -> [String] {
        let document = try SwiftSoup.parse(html)
        let elements = try document.select("[data-domain]")
        var domains = Set<String>()
        for element in elements {
            let domain = try element.attr("data-domain")
            if !domain.isEmpty { domains.insert(domain) }
        }
        return domains.sorted()
    }
}

private extension Optional where Wrapped == Int {
    func unwrap(or error: BootstrapError) throws -> Int {
        guard let self else { throw error }
        return self
    }
}
