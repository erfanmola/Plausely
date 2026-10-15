import AnalyticsCore
import Charts
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Deterministic breakdown loader for UI tests and previews. Generates 1500
/// rows (`Source 0001`… with repeating values so ties keep server order) and
/// honors the request's sort/search/pagination exactly like the server
/// contract: nil sort returns rank order, metric sorts put absent values
/// last, search is a case-insensitive name substring, pages slice by
/// limit/page. Production loaders arrive with the client-wiring follow-on.
public enum MockBreakdownProviders {
    public static let rowCount = 1500

    public static var loader: BreakdownModel.Loader {
        { request, today in
            var rows = dataset(for: request.kind)
            // Simulated server filtering: single-valued `is` clauses on
            // name-backed dimensions narrow by substring, like the
            // dashboard's filtered drilldowns. Dimensions the mock rows
            // don't carry are ignored.
            for clause in request.query.filters.clauses {
                guard clause.op == .is_, clause.values.count == 1,
                      case .text(let needle) = clause.values.first
                else { continue }
                switch clause.dimension {
                case .channel, .source, .referrer, .page, .name,
                     .utmMedium, .utmSource, .utmCampaign, .utmTerm, .utmContent,
                     .screen, .browser, .browserVersion, .os, .osVersion:
                    rows = rows.filter {
                        $0.name.localizedCaseInsensitiveContains(needle) || $0.code == needle
                    }
                case .country:
                    // Regions carry subdivision codes under their country.
                    rows = rows.filter {
                        $0.code == needle
                            || ($0.code?.hasPrefix(needle + "-") == true)
                            || $0.name.localizedCaseInsensitiveContains(needle)
                    }
                case .region:
                    // Cities link to regions through the mock region map.
                    rows = rows.filter {
                        $0.code == needle || regionCode(forCityCode: $0.code) == needle
                    }
                case .city:
                    rows = rows.filter {
                        $0.code == needle || $0.name.localizedCaseInsensitiveContains(needle)
                    }
                default:
                    continue
                }
            }
            if let query = request.search, !query.isEmpty {
                rows = rows.filter { $0.name.localizedCaseInsensitiveContains(query) }
            }
            rows = applySort(request.sort, to: rows)
            // Simulated server comparison: like the dashboard, comparison
            // values ride only when the query has a comparison. Previous
            // counts sit 50 below current (floored at zero, mirroring the
            // upstream "Google 2 vs 0 -> +100%" shape); other numerics echo.
            if request.query.comparison != .off {
                rows = rows.map(withComparison)
            }
            let limit: Int = request.pagination.limit
            let start: Int = (request.pagination.page - 1) * limit
            let end: Int = min(start + limit, rows.count)
            let page: [BreakdownRow] = start < rows.count ? Array(rows[start..<end]) : []
            let id = try QueryID.compute(for: request.query, today: today)
            return ReportEnvelope(queryID: id, value: BreakdownPage(rows: page), retrievedAt: today)
        }
    }

    /// Deterministic per-kind datasets. Sources keep the 1500-row tie-rich
    /// proof set; channels use distinct names; referrer drilldowns use
    /// gate-passable hostnames so Open actions render in tests.
    static func dataset(for kind: ReportKind = .sources) -> [BreakdownRow] {
        switch kind {
        case .channels:
            return (1...rowCount).map { index in
                channelRow(index: index)
            }
        case .referrerDrilldown:
            return (1...12).map { index in
                drilldownRow(index: index)
            }
        case .utmMediums:
            return utmRows(prefix: "UTM Medium", count: 40)
        case .utmSources:
            return utmRows(prefix: "UTM Source", count: 40)
        case .utmCampaigns:
            return utmRows(prefix: "UTM Campaign", count: 40)
        case .utmTerms:
            return utmRows(prefix: "UTM Term", count: 40)
        case .utmContents:
            return utmRows(prefix: "UTM Content", count: 40)
        case .pages:
            return pageRows()
        case .entryPages:
            return entryRows()
        case .exitPages:
            return exitRows()
        case .countries:
            return countryRows()
        case .regions:
            return regionRows()
        case .cities:
            return cityRows()
        case .screenSizes:
            return screenRows()
        case .browsers:
            return browserRows()
        case .browserVersions:
            return browserVersionRows()
        case .operatingSystems:
            return operatingSystemRows()
        case .operatingSystemVersions:
            return operatingSystemVersionRows()
        case .conversions:
            return conversionRows()
        case .customPropValues:
            return propValueRows()
        case .searchTerms:
            return searchTermRows()
        default:
            return dataset()
        }
    }

    private static func drilldownRow(index: Int) -> BreakdownRow {
        let visitors = 300 - index * 17
        return BreakdownRow(
            name: "referrer-\(index).example.com/article",
            metrics: [
                .visitors: .count(Int64(visitors)),
                .bounceRate: .count(100),
                .visitDuration: .count(0),
                .percentage: .decimal(Decimal(visitors) / Decimal(2000) * Decimal(100)),
            ]
        )
    }

    private static func utmRows(prefix: String, count: Int) -> [BreakdownRow] {
        (1...count).map { index in
            let visitors = Int64(5_000 - (index % 5) * 173 - index * 3)
            return BreakdownRow(
                name: "\(prefix) \(String(format: "%04d", index))",
                metrics: [
                    .visitors: .count(visitors),
                    .bounceRate: .count(100 - Int64(index % 4) * 5),
                    .visitDuration: .count(Int64(index % 9) * 11),
                    .percentage: .decimal(Decimal(visitors) / Decimal(5_000) * Decimal(100)),
                ]
            )
        }
    }

    /// Mock city geoname code to subdivision code, standing in for the
    /// server's region linkage in filtered drilldowns.
    static func regionCode(forCityCode code: String?) -> String? {
        guard let code else { return nil }
        return cityRegions[code]
    }

    private static let cityRegions: [String: String] = [
        "5391959": "US-CA", "4671654": "US-TX",
        "2867714": "DE-BY", "2950159": "DE-BE",
        "112931": "IR-07", "418863": "IR-04",
        "6167865": "CA-ON", "2988507": "FR-IDF",
    ]

    private static func countryRows() -> [BreakdownRow] {
        let countries: [(name: String, code: String, flag: String, visitors: Int64)] = [
            ("United States", "US", "🇺🇸", 1200), ("Germany", "DE", "🇩🇪", 900),
            ("Iran", "IR", "🇮🇷", 640), ("United Kingdom", "GB", "🇬🇧", 480),
            ("France", "FR", "🇫🇷", 360), ("Netherlands", "NL", "🇳🇱", 280),
            ("Canada", "CA", "🇨🇦", 210), ("Australia", "AU", "🇦🇺", 150),
            ("Japan", "JP", "🇯🇵", 110), ("Brazil", "BR", "🇧🇷", 80),
            ("India", "IN", "🇮🇳", 55), ("Spain", "ES", "🇪🇸", 30),
        ]
        return countries.map { entry in
            BreakdownRow(
                name: entry.name, code: entry.code, flag: entry.flag,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(4495) * Decimal(100)),
                ]
            )
        }
    }

    private static func regionRows() -> [BreakdownRow] {
        let regions: [(name: String, code: String, flag: String, visitors: Int64)] = [
            ("California", "US-CA", "🇺🇸", 700), ("Texas", "US-TX", "🇺🇸", 380),
            ("Bavaria", "DE-BY", "🇩🇪", 420), ("Berlin", "DE-BE", "🇩🇪", 310),
            ("Tehran", "IR-07", "🇮🇷", 390), ("Isfahan", "IR-04", "🇮🇷", 180),
            ("Ontario", "CA-ON", "🇨🇦", 150), ("Île-de-France", "FR-IDF", "🇫🇷", 220),
        ]
        return regions.map { entry in
            BreakdownRow(
                name: entry.name, code: entry.code, flag: entry.flag,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(2750) * Decimal(100)),
                ]
            )
        }
    }

    private static func cityRows() -> [BreakdownRow] {
        let cities: [(name: String, code: String, flag: String, visitors: Int64)] = [
            ("San Francisco", "5391959", "🇺🇸", 320), ("Austin", "4671654", "🇺🇸", 210),
            ("Munich", "2867714", "🇩🇪", 240), ("Berlin", "2950159", "🇩🇪", 310),
            ("Tehran", "112931", "🇮🇷", 390), ("Isfahan", "418863", "🇮🇷", 180),
            ("Toronto", "6167865", "🇨🇦", 150), ("Paris", "2988507", "🇫🇷", 220),
        ]
        return cities.map { entry in
            BreakdownRow(
                name: entry.name, code: entry.code, flag: entry.flag,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(2020) * Decimal(100)),
                ]
            )
        }
    }

    private static func screenRows() -> [BreakdownRow] {
        let screens: [(name: String, visitors: Int64, bounce: Int64, duration: Int64)] = [
            ("Desktop", 900, 40, 180), ("Mobile", 600, 55, 120),
            ("Tablet", 80, 60, 90), ("(not set)", 20, 100, 0),
        ]
        return screens.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .bounceRate: .count(entry.bounce),
                    .visitDuration: .count(entry.duration),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(1600) * Decimal(100)),
                ]
            )
        }
    }

    private static func browserRows() -> [BreakdownRow] {
        // Live-shaped: name + visitors + share only, no engagement keys.
        let browsers: [(name: String, visitors: Int64)] = [
            ("Chrome", 658), ("Safari", 645),
            ("Microsoft Edge", 297), ("Firefox", 120), ("(not set)", 10),
        ]
        return browsers.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(1730) * Decimal(100)),
                ]
            )
        }
    }

    private static func browserVersionRows() -> [BreakdownRow] {
        // Parent-prefixed names so the mock's substring filter can serve
        // version drilldowns; the detailed server shape (version-only name)
        // is pinned by fixtures + adapter tests instead.
        let versions: [(name: String, visitors: Int64, bounce: Int64, duration: Int64)] = [
            ("Chrome 119.0", 400, 42, 170), ("Chrome 118.0", 180, 45, 150),
            ("Safari 17.1", 380, 0, 0), ("Safari 16.6", 200, 0, 0),
            ("Firefox 120.0", 90, 50, 110), ("Edge 119.0", 210, 44, 160),
        ]
        return versions.map { entry in
            var metrics: [MetricID: MetricValue] = [
                .visitors: .count(entry.visitors),
                .percentage: .decimal(Decimal(entry.visitors) / Decimal(1460) * Decimal(100)),
            ]
            // Safari rows mirror engagement-unavailable gaps.
            if entry.name.hasPrefix("Chrome") || entry.name.hasPrefix("Edge") || entry.name.hasPrefix("Firefox") {
                metrics[.bounceRate] = .count(entry.bounce)
                metrics[.visitDuration] = .count(entry.duration)
            }
            return BreakdownRow(name: entry.name, metrics: metrics)
        }
    }

    private static func operatingSystemRows() -> [BreakdownRow] {
        let systems: [(name: String, visitors: Int64)] = [
            ("Mac", 700), ("Windows", 480),
            ("iOS", 420), ("Android", 180), ("Linux", 60), ("(not set)", 10),
        ]
        return systems.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(1850) * Decimal(100)),
                ]
            )
        }
    }

    private static func operatingSystemVersionRows() -> [BreakdownRow] {
        let versions: [(name: String, visitors: Int64)] = [
            ("Mac 14.1", 420), ("Mac 13.6", 180),
            ("Windows 11", 300), ("Windows 10", 150),
            ("iOS 17.1", 260), ("Android 14", 120),
        ]
        return versions.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(1430) * Decimal(100)),
                ]
            )
        }
    }

    private static func conversionRows() -> [BreakdownRow] {
        // Live-shaped: Signup + pageview goal + repeated event goal.
        let goals: [(name: String, visitors: Int64, events: Int64, rate: String)] = [
            ("Signup", 200, 200, "12.5"),
            ("Visit /checkout/success", 77, 77, "4.81"),
            ("Purchase", 30, 45, "1.88"),
        ]
        return goals.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .events: .count(entry.events),
                    .conversionRate: .decimal(Decimal(string: entry.rate)!),
                ]
            )
        }
    }

    private static func propValueRows() -> [BreakdownRow] {
        let values: [(name: String, visitors: Int64, events: Int64)] = [
            ("Monthly", 800, 950), ("Yearly", 420, 430), ("(none)", 180, 180),
        ]
        return values.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .events: .count(entry.events),
                    .percentage: .decimal(Decimal(entry.visitors) / Decimal(1400) * Decimal(100)),
                ]
            )
        }
    }

    private static func searchTermRows() -> [BreakdownRow] {
        // Live-shaped GSC rows: visitors plus position/CTR/impressions,
        // no engagement or share columns (verified against CE 3.2.1).
        let terms: [(name: String, visitors: Int64, impressions: Int64, ctr: String, position: String)] = [
            ("compass online", 100, 1463, "6.8", "3.8"),
            ("qibla direction", 66, 408, "16.2", "4.8"),
            ("online compass", 26, 348, "7.5", "8.4"),
            ("prayer direction finder", 21, 83, "25.3", "18.7"),
            ("north finder", 19, 430, "4.4", "7.0"),
        ]
        return terms.map { entry in
            BreakdownRow(
                name: entry.name,
                metrics: [
                    .visitors: .count(entry.visitors),
                    .impressions: .count(entry.impressions),
                    .ctr: .decimal(Decimal(string: entry.ctr)!),
                    .position: .decimal(Decimal(string: entry.position)!),
                ]
            )
        }
    }

    private static let pagePool = ["/", "/pricing", "/blog", "/checkout/success", "/docs", "/about"]

    private static func pageRows() -> [BreakdownRow] {
        (1...60).map { index in
            let path = "\(pagePool[index % pagePool.count])\(index < 6 ? "" : "-\(index)")"
            return BreakdownRow(
                name: path,
                metrics: [
                    .visitors: .count(Int64(500 - index * 7)),
                    .pageviews: .count(Int64(620 - index * 8)),
                    .bounceRate: .count(100 - Int64(index % 3) * 7),
                    // Contextual engagement is unavailable for most rows,
                    // exactly like the server's nulls.
                    .timeOnPage: index % 3 == 0 ? .count(Int64(20 + index)) : .unavailable(.null),
                    .scrollDepth: index % 4 == 0 ? .decimal(Decimal(40 + index)) : .unavailable(.null),
                    .percentage: .decimal(Decimal(500 - index * 7) / Decimal(1600) * Decimal(100)),
                ]
            )
        }
    }

    private static func entryRows() -> [BreakdownRow] {
        (1...40).map { index in
            let visits = Int64(450 - index * 9)
            return BreakdownRow(
                name: "\(pagePool[index % pagePool.count])\(index < 6 ? "" : "-\(index)")",
                // Entrances ride visits and never equal pageviews: the mock
                // keeps no pageviews column here at all, like the server.
                metrics: [
                    .visitors: .count(visits),
                    .visits: .count(visits),
                    .bounceRate: .count(100),
                    .visitDuration: .count(Int64(index % 7) * 5),
                    .percentage: .decimal(Decimal(visits) / Decimal(1400) * Decimal(100)),
                ]
            )
        }
    }

    private static func exitRows() -> [BreakdownRow] {
        (1...40).map { index in
            let visits = Int64(450 - index * 9)
            return BreakdownRow(
                name: "\(pagePool[index % pagePool.count])\(index < 6 ? "" : "-\(index)")",
                metrics: [
                    .visitors: .count(visits),
                    .visits: .count(visits),
                    .exitRate: .decimal(Decimal(100 - index % 30)),
                    .percentage: .decimal(Decimal(visits) / Decimal(1400) * Decimal(100)),
                ]
            )
        }
    }

    static func dataset() -> [BreakdownRow] {
        (1...rowCount).map { index in
            // Seven repeating values: ties prove the model never re-sorts.
            let visitors = Int64(100_000 - (index % 7) * 137 - index / 7)
            return BreakdownRow(
                name: String(format: "Source %04d", index),
                metrics: [
                    .visitors: .count(visitors),
                    .percentage: .decimal(Decimal(visitors) / Decimal(100_000) * Decimal(100)),
                ]
            )
        }
    }

    private static func channelRow(index: Int) -> BreakdownRow {
        let pool = ["Organic Search", "Direct", "Email", "Social", "Paid Search", "Referral"]
        let visitors = Int64(50_000 - (index % 7) * 211 - index / 7)
        return BreakdownRow(
            name: "\(pool[index % pool.count]) \(String(format: "%04d", index))",
            metrics: [
                .visitors: .count(visitors),
                .bounceRate: .count(100 - Int64(index % 5) * 3),
                .visitDuration: .count(Int64(index % 11) * 7),
                .percentage: .decimal(Decimal(visitors) / Decimal(50_000) * Decimal(100)),
            ]
        )
    }

    /// Fake-server comparison payload: previous counts 50 below current
    /// (floored at zero), decimals echoed, nulls staying null with no
    /// delta. Change is the fake server's percent, never client math over
    /// real data.
    static func withComparison(_ row: BreakdownRow) -> BreakdownRow {
        var comparison: [MetricID: MetricValue] = [:]
        var change: [MetricID: Int?] = [:]
        for (metric, value) in row.metrics {
            switch value {
            case .count(let amount):
                let prev = max(amount - 50, 0)
                comparison[metric] = .count(prev)
                let delta: Int = prev == 0 ? (amount == 0 ? 0 : 100) : Int((Double(amount - prev) / Double(prev) * 100).rounded())
                change.updateValue(delta, forKey: metric)
            case .decimal(let amount):
                comparison[metric] = .decimal(amount)
                change.updateValue(0, forKey: metric)
            case .unavailable(let reason):
                comparison[metric] = .unavailable(reason)
            }
        }
        return BreakdownRow(name: row.name, code: row.code, metrics: row.metrics, comparison: comparison, change: change)
    }

    static func applySort(_ sort: ReportSort?, to rows: [BreakdownRow]) -> [BreakdownRow] {        guard let sort else { return rows }
        switch sort.key {
        case .dimension:
            let ordered = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return sort.direction == .ascending ? ordered : ordered.reversed()
        case .metric(let metric):
            let withValue = rows.map { ($0, number($0.metrics[metric])) }
            let ordered = withValue.sorted { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (a?, b?): return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }.map(\.0)
            return sort.direction == .ascending ? ordered : ordered.reversed()
        }
    }

    private static func number(_ value: MetricValue?) -> Double? {
        switch value {
        case .count(let amount): return Double(amount)
        case .decimal(let amount): return NSDecimalNumber(decimal: amount).doubleValue
        case .none, .unavailable: return nil
        }
    }
}

/// Server change badge for one metric: short arrow text with the full
/// comparison sentence as its voice label. Renders nothing without a
/// comparison delta (comparison off, or the server left it uncomputable).
/// Direction rides arrow + sign + words, never color alone (MET-04).
struct BreakdownChangeBadge: View {
    private let row: BreakdownRow
    private let metric: MetricID
    private let prefix: String
    private let index: Int?

    init(row: BreakdownRow, metric: MetricID, prefix: String, index: Int? = nil) {
        self.row = row
        self.metric = metric
        self.prefix = prefix
        self.index = index
    }

    var body: some View {
        if let short = shortChangeText(row.change[metric] ?? nil),
           let full = changeText(row.change[metric] ?? nil)
        {
            Text(short)
                .font(.caption2)
                .foregroundStyle(changeDirectionColor(row.change[metric] ?? nil))
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(full)
        }
    }

    private var identifier: String {
        if let index {
            return "\(prefix)-change-\(index)-\(metric.rawValue)"
        }
        return "\(prefix)-change-\(metric.rawValue)"
    }
}

/// Compact change text for badges; the full sentence stays the voice label.
func shortChangeText(_ change: Int?) -> String? {
    guard let change else { return nil }
    if change > 0 { return "▲ +\(change)%" }
    if change < 0 { return "▼ \(change)%" }
    return "■ 0%"
}

/// Country distribution visualization (GEO-01): horizontal bars for the
/// top ranked countries with exact-value selection. The ranked summary
/// below stays the accessible equivalent — the chart never carries numbers
/// VoiceOver can't reach elsewhere.
public struct CountryDistributionView: View {
    @Bindable private var model: BreakdownModel
    @State private var selection: String?

    public init(model: BreakdownModel) {
        self.model = model
    }

    private struct Bar: Hashable {
        let name: String
        let visitors: Double
    }

    private var bars: [Bar] {
        model.rows.prefix(8).compactMap { row in
            guard case .count(let visitors) = row.metrics[.visitors] else { return nil }
            return Bar(name: row.name, visitors: Double(visitors))
        }
    }

    public var body: some View {
        if !bars.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Chart(bars, id: \.name) { bar in
                    BarMark(
                        x: .value("Visitors", bar.visitors),
                        y: .value("Country", bar.name)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
                .chartYSelection(value: $selection)
                .chartXAxis(.hidden)
                .frame(minHeight: CGFloat(max(120, bars.count * 28)))
                .accessibilityLabel("Top countries by visitors, \(bars.count) bars")
                .accessibilityIdentifier("country-chart")
                .sensoryFeedback(.selection, trigger: selection)
                if let selection, let bar = bars.first(where: { $0.name == selection }) {
                    Text("\(bar.name): \(Int(bar.visitors)) visitors")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("country-selection")
                }
            }
        }
    }
}

/// Native context actions for one breakdown row: filter by the row's
/// dimension where the family supports it, open the link where the
/// family allows it, and always copy the name. Every action degrades
/// away when unsupported, so the menu never offers a dead row.
struct RowContextMenu: ViewModifier {
    let definition: ReportDefinition
    let row: BreakdownRow
    let siteDomain: String?
    let onFilter: BreakdownFilterAction?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.contextMenu {
            if let dimension = definition.filterDimension,
               let clause = definition.filterClause(for: row.name, code: row.code),
               onFilter != nil
            {
                Button {
                    _ = onFilter?(clause)
                } label: {
                    Label(
                        "Filter by this \(dimensionName(dimension).lowercased())",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
            }
            if let url = openTarget {
                Button {
                    openURL(url)
                } label: {
                    Label("Open link", systemImage: "arrow.up.forward.app")
                }
            }
            Button {
                copyName()
            } label: {
                Label("Copy name", systemImage: "doc.on.doc")
            }
        }
    }

    /// Same Open resolution as the row detail: self-contained URLs
    /// through the gate, or site-relative paths against the site domain.
    private var openTarget: URL? {
        if definition.allowsExternalOpen {
            return ExternalLinkGate.url(for: row.name)
        }
        if definition.pagePaths, let siteDomain, row.name.hasPrefix("/") {
            return ExternalLinkGate.url(for: "https://\(siteDomain)\(row.name)")
        }
        return nil
    }

    private func copyName() {
#if os(iOS)
        UIPasteboard.general.string = row.name
#else
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(row.name, forType: .string)
#endif
    }
}

/// Row glyph: the dashboard flag emoji for geo rows, a remote favicon for
/// host rows (sources + referrer URLs via DuckDuckGo's privacy-friendly
/// icon proxy, AsyncImage-cached, family symbol while loading/on error),
/// the family symbol otherwise. Decorative; always hidden from VoiceOver.
struct RowGlyph: View {
    let definition: ReportDefinition
    let row: BreakdownRow

    var body: some View {
        Group {
            if let flag = row.flag {
                Text(flag)
            } else {
                switch BreakdownIconResolver.icon(for: row, kind: definition.kind) {
                case .favicon(let host):
                    CachedFaviconImage(host: host, fallback: reportSymbolName(for: definition.kind))
                case .system(let name):
                    Image(systemName: name)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 24, height: 24, alignment: .center)
        .accessibilityHidden(true)
    }
}


/// Compact embed: top rows plus a Show-all link. Drives the shared model from
/// the effective query; the full report destination reuses the same model.
public struct BreakdownSummaryView: View {
    @Bindable private var model: BreakdownModel
    private let query: DashboardQuery?
    private let isActive: Bool
    private let previewCount: Int
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    @State private var showingFull = false
    private let formatter = MetricFormatter()

    public init(
        model: BreakdownModel,
        query: DashboardQuery?,
        previewCount: Int = 5,
        childFactory: BreakdownChildFactory? = nil,
        onFilter: BreakdownFilterAction? = nil,
        isActive: Bool = true
    ) {
        self.model = model
        self.query = query
        self.isActive = isActive
        self.previewCount = previewCount
        self.childFactory = childFactory
        self.onFilter = onFilter
    }

    /// Top primary-column value across loaded rows: bar widths are shares
    /// of it. Zero/unknown data yields an empty max and zero fractions.
    private var maxPrimaryValue: Double {
        guard let primary = model.definition.columns.first else { return 0 }
        return model.rows.compactMap { row in
            row.metrics[primary].flatMap(SeriesPoints.plotDouble)
        }.max() ?? 0
    }

    private func barFraction(_ row: BreakdownRow, ceiling: Double) -> Double {
        guard ceiling > 0,
              let primary = model.definition.columns.first,
              let value = row.metrics[primary].flatMap(SeriesPoints.plotDouble)
        else { return 0 }
        return Swift.max(0, Swift.min(1, value / ceiling))
    }

    public var body: some View {
        let prefix = model.definition.idPrefix
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.warnings.enumerated()), id: \.offset) { index, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(prefix)-warning-\(index)")
            }
            switch model.state {
            case .idle, .loading where model.rows.isEmpty:
                SummaryRowsSkeleton(rows: previewCount)
                    .accessibilityIdentifier("\(prefix)-summary-loading")
            case .failed where model.rows.isEmpty:
                ContentUnavailableView {
                    Label("Couldn't load \(model.definition.title.lowercased()).", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Check the connection and open the full report to retry.")
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(prefix)-summary-error")
            default:
                if model.rows.isEmpty {
                    ContentUnavailableView(
                        "No data for this period",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Values appear here once the site collects matching traffic.")
                    )
                    .accessibilityIdentifier("\(prefix)-summary-empty")
                } else {
                    ForEach(Array(model.rows.prefix(previewCount).enumerated()), id: \.offset) { index, row in                    // Full-width proportional bar (dashboard style): width
                    // encodes share of the top row, name rides inside,
                    // exact value stays right-aligned text.
                    let fraction = barFraction(row, ceiling: maxPrimaryValue)
                    ZStack(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule(style: .continuous)
                                .fill(HomeStyle.barFill)
                                .frame(
                                    width: max(64, proxy.size.width * fraction),
                                    height: 46
                                )
                                .accessibilityHidden(true)
                        }
                        .frame(height: 46)
                        HStack(spacing: 8) {
                            RowGlyph(definition: model.definition, row: row)
                            Text(row.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if let primary = model.definition.columns.first,
                               let value = row.metrics[primary]
                            {
                                Text(formatter.string(for: value, as: primary))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.snappy, value: value)
                                BreakdownChangeBadge(row: row, metric: primary, prefix: "\(prefix)-summary", index: index)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    // Full-bounds hit testing: without an explicit shape
                    // only rendered content (the bar, the texts) answers
                    // long-press, leaving the row's empty stretch dead.
                    .contentShape(Rectangle())
                    .modifier(RowContextMenu(
                        definition: model.definition, row: row,
                        siteDomain: query?.siteID.domain, onFilter: onFilter
                    ))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(prefix)-summary-\(index)")
                }
                if !model.rows.isEmpty {
                    Button("Show all \(model.definition.title.lowercased())") { showingFull = true }
                        .accessibilityIdentifier("\(prefix)-show-all")
                        .sheet(isPresented: $showingFull) {
                            BreakdownSheetHost(
                                model: model, childFactory: childFactory, onFilter: onFilter,
                                onCloseSheet: { showingFull = false }
                            )
                        }
                } else if case .loading = model.state {
                    // Invisible slot: the button legitimately arrives with
                    // the rows, and its appearance must not push the cards
                    // below down.
                    Button("Show all \(model.definition.title.lowercased())") {}
                        .disabled(true)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
                }
            }
        }
        .task(id: isActive ? query : nil) {
            guard isActive else { return }
            if let query { await model.updateQuery(query) }
            if case .idle = model.state { await model.load() }
        }
    }
}

/// Shared wiring types: child-report factory (drill target + current query
/// to a fresh model, merging any hierarchy filter) and row-filter action
/// (clause to the query model, true when accepted). Both run on the main
/// actor: factories build MainActor models and actions mutate them.
public typealias BreakdownChildFactory = @MainActor @Sendable (DrillTarget, DashboardQuery) -> BreakdownModel
public typealias BreakdownFilterAction = @MainActor @Sendable (FilterClause) -> Bool

/// Shared navigation destinations for every breakdown stack (sheet roots
/// and hub lists alike): drill children and row details resolve in exactly
/// one place, so nested reports can never shadow each other.
public struct BreakdownStackDestinations: ViewModifier {
    private let baseQuery: DashboardQuery
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    private let pop: () -> Void
    private let dismissSheet: () -> Void

    public init(
        baseQuery: DashboardQuery,
        childFactory: BreakdownChildFactory?,
        onFilter: BreakdownFilterAction?,
        pop: @escaping () -> Void,
        dismissSheet: @escaping () -> Void = {}
    ) {
        self.baseQuery = baseQuery
        self.childFactory = childFactory
        self.onFilter = onFilter
        self.pop = pop
        self.dismissSheet = dismissSheet
    }

    public func body(content: Content) -> some View {
        content
            .navigationDestination(for: DrillTarget.self) { target in
                BreakdownReportView(
                    model: childFactory?(target, baseQuery) ?? BreakdownModel(
                        definition: breakdownDefinition(for: target.kind, title: target.title),
                        query: breakdownQuery(baseQuery, adding: target.filter),
                        loader: MockBreakdownProviders.loader
                    ),
                    childFactory: childFactory,
                    onFilter: onFilter,
                    onDone: pop,
                    pop: pop
                )
            }
            .navigationDestination(for: BreakdownRowTarget.self) { target in
                BreakdownRowDetailView(
                    row: target.row,
                    definition: breakdownDefinition(for: target.kind),
                    onFilter: onFilter,
                    onDone: pop,
                    dismissSheet: dismissSheet,
                    siteDomain: baseQuery.siteID.domain
                )
            }
    }
}

/// Entry row opening the UTM family hub sheet. The hub lists the five
/// verified UTM families; each pushes its full report with the shared
/// stack destinations.
public struct BreakdownHubButton: View {
    private let query: DashboardQuery
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    @State private var showingHub = false

    public init(query: DashboardQuery, childFactory: BreakdownChildFactory?, onFilter: BreakdownFilterAction?) {
        self.query = query
        self.childFactory = childFactory
        self.onFilter = onFilter
    }

    public var body: some View {
        Button("UTM reports") { showingHub = true }
            .accessibilityIdentifier("breakdown-utm-hub")
            .sheet(isPresented: $showingHub) {
                BreakdownHubSheetHost(
                    title: "UTM reports",
                    families: ReportDefinition.utmFamilies,
                    query: query,
                    childFactory: childFactory,
                    onFilter: onFilter,
                    onCloseSheet: { showingHub = false }
                )
            }
    }
}
/// Entry row opening the property-values sheet. Property keys are not
/// enumerable server-side, so the key is entered manually; values then
/// push a full report through the shared stack destinations.
public struct PropsHubButton: View {
    private let query: DashboardQuery
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    @State private var showingProps = false

    public init(query: DashboardQuery, childFactory: BreakdownChildFactory?, onFilter: BreakdownFilterAction?) {
        self.query = query
        self.childFactory = childFactory
        self.onFilter = onFilter
    }

    public var body: some View {
        Button("Properties") { showingProps = true }
            .accessibilityIdentifier("breakdown-props-hub")
            .sheet(isPresented: $showingProps) {
                PropsSheetHost(
                    query: query,
                    childFactory: childFactory,
                    onFilter: onFilter,
                    onCloseSheet: { showingProps = false }
                )
            }
    }
}

/// Property key entry plus the values report inside this sheet's own stack.
public struct PropsSheetHost: View {
    private let query: DashboardQuery
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    private let onCloseSheet: () -> Void
    @State private var key = ""
    @State private var path = NavigationPath()

    public init(
        query: DashboardQuery,
        childFactory: BreakdownChildFactory?,
        onFilter: BreakdownFilterAction?,
        onCloseSheet: @escaping () -> Void
    ) {
        self.query = query
        self.childFactory = childFactory
        self.onFilter = onFilter
        self.onCloseSheet = onCloseSheet
    }

    public var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField("Property key (e.g. plan)", text: $key)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                        .accessibilityIdentifier("breakdown-props-key")
                }
                Section {
                    Button("Show values") {
                        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        path.append(DrillTarget(
                            kind: .customPropValues(key: trimmed), title: trimmed
                        ))
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("breakdown-props-open")
                }
            }
            .navigationTitle("Properties")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onCloseSheet)
                        .accessibilityIdentifier("breakdown-props-close")
                }
            }
            .modifier(BreakdownStackDestinations(
                baseQuery: query,
                childFactory: childFactory,
                onFilter: onFilter,
                pop: { if !path.isEmpty { path.removeLast() } },
                dismissSheet: onCloseSheet
            ))
        }
        .accessibilityIdentifier("breakdown-props")
    }
}
/// UTM family hub: one row per UTM family; each pushes its full report
/// inside this sheet's own stack. Counts stay in the reports themselves;
/// the hub lists families only.
public struct BreakdownHubSheetHost: View {
    private let title: String
    private let families: [ReportDefinition]
    private let query: DashboardQuery
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    private let onCloseSheet: () -> Void
    @State private var path = NavigationPath()

    public init(
        title: String,
        families: [ReportDefinition],
        query: DashboardQuery,
        childFactory: BreakdownChildFactory?,
        onFilter: BreakdownFilterAction?,
        onCloseSheet: @escaping () -> Void
    ) {
        self.title = title
        self.families = families
        self.query = query
        self.childFactory = childFactory
        self.onFilter = onFilter
        self.onCloseSheet = onCloseSheet
    }

    public var body: some View {
        NavigationStack(path: $path) {
            // Declarative links through the stack path, in a lazy stack. A
            // List is avoided deliberately: List rows render Disabled inside
            // macOS sheets and never become hittable.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(families, id: \.kind) { family in
                        NavigationLink(value: DrillTarget(kind: family.kind, title: family.title)) {
                            HStack {
                                Label(family.title, systemImage: reportSymbolName(for: family.kind))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 6)
                        }
                        .accessibilityIdentifier("breakdown-hub-\(family.kind.path())")
                    }
                }
                .padding()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onCloseSheet)
                        .accessibilityIdentifier("breakdown-hub-close")
                }
            }
            .modifier(BreakdownStackDestinations(
                baseQuery: query,
                childFactory: childFactory,
                onFilter: onFilter,
                pop: { if !path.isEmpty { path.removeLast() } },
                dismissSheet: onCloseSheet
            ))
        }
        .accessibilityIdentifier("breakdown-hub")
    }
}
/// Row detail target: the row travels with the link, so any registrar
/// builds the exact row — no name lookup can miss. The host resolves the
/// family definition by kind, so columns/filter/Open are always right.
public struct BreakdownRowTarget: Hashable, Sendable {
    public let kind: ReportKind
    public let row: BreakdownRow
    public init(kind: ReportKind, row: BreakdownRow) {
        self.kind = kind
        self.row = row
    }
}

public struct BreakdownSheetHost: View {
    @Bindable private var model: BreakdownModel
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    private let onCloseSheet: () -> Void
    @State private var path = NavigationPath()

    public init(
        model: BreakdownModel,
        childFactory: BreakdownChildFactory? = nil,
        onFilter: BreakdownFilterAction? = nil,
        onCloseSheet: @escaping () -> Void = {}
    ) {
        self.model = model
        self.childFactory = childFactory
        self.onFilter = onFilter
        self.onCloseSheet = onCloseSheet
    }

    public var body: some View {
        NavigationStack(path: $path) {
            BreakdownReportView(
                model: model, childFactory: childFactory, onFilter: onFilter,
                onDone: onCloseSheet,
                pop: { if !path.isEmpty { path.removeLast() } }
            )
            .modifier(BreakdownStackDestinations(
                baseQuery: model.query,
                childFactory: childFactory,
                onFilter: onFilter,
                pop: { if !path.isEmpty { path.removeLast() } },
                dismissSheet: onCloseSheet
            ))
        }
        .accessibilityIdentifier("breakdown-full")
    }
}

/// Full report: search (where supported), server sort, paged rows with
/// drilldown navigation or all-column leaf detail, and a completeness
/// footer for later export phases.
public struct BreakdownReportView: View {
    @Bindable private var model: BreakdownModel
    private let childFactory: BreakdownChildFactory?
    private let onFilter: BreakdownFilterAction?
    private let onDone: () -> Void
    private let pop: () -> Void
    @State private var searchText: String = ""
    @State private var searchDebounce: Task<Void, Never>?
    private let formatter = MetricFormatter()

    public init(
        model: BreakdownModel,
        childFactory: BreakdownChildFactory? = nil,
        onFilter: BreakdownFilterAction? = nil,
        onDone: @escaping () -> Void = {},
        pop: @escaping () -> Void = {}
    ) {
        self.model = model
        self.childFactory = childFactory
        self.onFilter = onFilter
        self.onDone = onDone
        self.pop = pop
    }

    private var prefix: String { model.definition.idPrefix }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.definition.supportsSearch {
                    TextField("Search \(model.definition.title.lowercased())", text: $searchText)
                        .accessibilityIdentifier("\(prefix)-search")
                }
                sortChips
                reportContent
                completenessFooter
            }
            .padding()
        }
        .refreshable {
            await model.load(today: Date())
        }
        .sensoryFeedback(.selection, trigger: model.sort)
        .onChange(of: searchText) { _, query in
            // Explicit latest-wins debounce: the previous task dies on
            // every keystroke; only the settled text reaches the server.
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await model.setSearch(query)
            }
        }
        .navigationTitle(model.definition.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onDone)
                    .accessibilityIdentifier("\(prefix)-close")
            }
        }
        .task {
            if case .idle = model.state { await model.load() }
        }
    }

    private struct SortOption: Hashable {
        let id: String
        let title: String
        let sort: ReportSort?
    }

    private var sortOptions: [SortOption] {
        var options: [SortOption] = [
            SortOption(id: "default", title: "Server order", sort: nil),
            SortOption(id: "name-asc", title: "Name A–Z", sort: ReportSort(key: .dimension("name"), direction: .ascending)),
            SortOption(id: "name-desc", title: "Name Z–A", sort: ReportSort(key: .dimension("name"), direction: .descending)),
        ]
        for metric in model.definition.columns {
            let name = MetricID.descriptor(for: metric).displayName
            options.append(SortOption(
                id: "\(metric.rawValue)-desc", title: "\(name) ↓",
                sort: ReportSort(key: .metric(metric), direction: .descending)
            ))
            options.append(SortOption(
                id: "\(metric.rawValue)-asc", title: "\(name) ↑",
                sort: ReportSort(key: .metric(metric), direction: .ascending)
            ))
        }
        return options
    }

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sortOptions, id: \.id) { option in
                    sortChip(option)
                }
            }
        }
        .accessibilityIdentifier("\(prefix)-sort")
    }

    private func sortChip(_ option: SortOption) -> some View {
        Button(option.title) {
            Task { await model.setSort(option.sort) }
        }
        .buttonStyle(.bordered)
        .bold(option.sort == model.sort)
        .accessibilityIdentifier("sort-option-\(prefix)-\(option.id)")
    }

    @ViewBuilder
    private var reportContent: some View {
        switch model.state {
        case .idle, .loading where model.rows.isEmpty:
            ProgressView("Loading \(model.definition.title.lowercased())…")
                .accessibilityIdentifier("\(prefix)-loading")
        case .failed(let error) where model.rows.isEmpty:
            VStack(alignment: .leading, spacing: 4) {
                Text(error.message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(prefix)-error")
                Button("Retry") { Task { await model.retry() } }
                    .accessibilityIdentifier("\(prefix)-retry")
            }
        case .loaded where model.rows.isEmpty:
            ContentUnavailableView(
                "No data for this period",
                systemImage: "tray",
                description: Text("Rows appear here once the site collects matching traffic.")
            )
            .accessibilityIdentifier("\(prefix)-empty")
        default:
            ForEach(Array(model.warnings.enumerated()), id: \.offset) { index, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(prefix)-warning-\(index)")
            }
            dataGrid
            if case .failed(let error) = model.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("\(prefix)-error-inline")
                    Button("Retry") { Task { await model.retry() } }
                        .accessibilityIdentifier("\(prefix)-retry")
                }
            }
            if case .loading = model.state {
                ProgressView()
                    .accessibilityIdentifier("\(prefix)-more-loading")
            } else if model.hasMore {
                Button("Load more") { Task { await model.loadMore() } }
                    .accessibilityIdentifier("\(prefix)-more")
            }
        }
    }

    private var completenessFooter: some View {
        Text(model.hasMore
            ? "Showing \(model.rows.count) rows; more available."
            : "Showing \(model.rows.count) rows; complete.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("\(prefix)-count")
    }

    // MARK: - Rows

    /// Lazy aligned grid on both platforms: every column always renders
    /// (nothing collapses away like Table's automatic columns), rows stay
    /// lazy for long reports, and sorting stays server-side via the menu.
    private var dataGrid: some View {
        // Wide families (pages: 6 metric columns) exceed phone widths:
        // scroll horizontally instead of clipping columns away. A Grid
        // (not LazyVGrid) keeps every column aligned across rows on both
        // platforms and keeps cells visible to accessibility: LazyVGrid
        // drops static cell content from the AX tree and, on iOS, never
        // rendered the value cells at all (blank since 05.1, proven by
        // period screenshots). Pages stay small because the model paginates
        // server-side, so nothing lazy is lost.
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(model.definition.columns, id: \.self) { metric in
                        Text(MetricID.descriptor(for: metric).displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
                ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        nameCell(row: row, index: index)
                        ForEach(model.definition.columns, id: \.self) { metric in
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(row.metrics[metric].map { formatter.string(for: $0, as: metric) } ?? "–")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if let short = shortChangeText(row.change[metric] ?? nil) {
                                    Text(short)
                                        .font(.caption2)
                                        .foregroundStyle(changeDirectionColor(row.change[metric] ?? nil))
                                }
                            }
                            .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nameCell(row: BreakdownRow, index: Int) -> some View {
        // Every push navigates by value through the sheet stack's path, so
        // one pop always returns exactly one level, deterministically.
        // Destinations live only on the sheet host (never per report):
        // nested registrars shadow each other and miss on lookup.
        if let target = model.definition.drilldown(row), childFactory != nil {
            NavigationLink(value: target) {
                HStack {
                    RowGlyph(definition: model.definition, row: row)
                    Text(row.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .modifier(RowContextMenu(
                    definition: model.definition, row: row,
                    siteDomain: model.query.siteID.domain, onFilter: onFilter
                ))
            }
            .accessibilityIdentifier("\(prefix)-row-\(index)")
        } else {
            NavigationLink(value: BreakdownRowTarget(kind: model.definition.kind, row: row)) {
                HStack {
                    RowGlyph(definition: model.definition, row: row)
                    Text(row.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .modifier(RowContextMenu(
                    definition: model.definition, row: row,
                    siteDomain: model.query.siteID.domain, onFilter: onFilter
                ))
            }
            .accessibilityIdentifier("\(prefix)-row-\(index)")
        }
    }
}

/// All-column detail for one row. Absent columns stay absent, never zero.
/// Filter applies the family's dimension for this row to the dashboard
/// query; Open appears only for real URLs through the external gate.
public struct BreakdownRowDetailView: View {
    private let row: BreakdownRow
    private let definition: ReportDefinition
    private let onFilter: BreakdownFilterAction?
    private let onDone: () -> Void
    private let dismissSheet: () -> Void
    private let siteDomain: String?
    private let formatter = MetricFormatter()
    @Environment(\.openURL) private var openURL
    @State private var localError: String?
    @State private var appliedFilterTick = 0

    public init(
        row: BreakdownRow,
        definition: ReportDefinition,
        onFilter: BreakdownFilterAction? = nil,
        onDone: @escaping () -> Void = {},
        dismissSheet: @escaping () -> Void = {},
        siteDomain: String? = nil
    ) {
        self.row = row
        self.definition = definition
        self.onFilter = onFilter
        self.onDone = onDone
        self.dismissSheet = dismissSheet
        self.siteDomain = siteDomain
    }

    private var prefix: String { definition.idPrefix }

    /// Open target: self-contained URLs through the gate, or site-relative
    /// paths resolved against the site domain (also gated). Anything else
    /// offers no Open action.
    private var openTarget: URL? {
        if definition.allowsExternalOpen {
            return ExternalLinkGate.url(for: row.name)
        }
        if definition.pagePaths, let siteDomain, row.name.hasPrefix("/") {
            return ExternalLinkGate.url(for: "https://\(siteDomain)\(row.name)")
        }
        return nil
    }

    public var body: some View {
        Form {
            LabeledContent("Name", value: "\(row.flag.map { "\($0) " } ?? "")\(row.name)")
                .accessibilityIdentifier("\(prefix)-detail-name")
            if let code = row.code {
                LabeledContent("Code", value: code)
            }
            ForEach(definition.columns, id: \.self) { metric in
                if let value = row.metrics[metric] {
                    LabeledContent(
                        MetricID.descriptor(for: metric).displayName,
                        value: formatter.string(for: value, as: metric)
                    )
                    .accessibilityIdentifier("\(prefix)-detail-\(metric.rawValue)")
                    if let previous = row.comparison?[metric] {
                        LabeledContent(
                            "\(MetricID.descriptor(for: metric).displayName) previous period",
                            value: formatter.string(for: previous, as: metric)
                        )
                        .accessibilityIdentifier("\(prefix)-detail-\(metric.rawValue)-comparison")
                    }
                    if let short = shortChangeText(row.change[metric] ?? nil) {
                        LabeledContent(
                            "\(MetricID.descriptor(for: metric).displayName) change",
                            value: short
                        )
                        .foregroundStyle(changeDirectionColor(row.change[metric] ?? nil))
                        .accessibilityIdentifier("\(prefix)-detail-\(metric.rawValue)-change")
                    }
                }
            }
            if let dimension = definition.filterDimension, onFilter != nil {
                Button("Filter by this \(dimensionLabel(dimension))") {
                    if let clause = definition.filterClause(for: row.name, code: row.code),
                       onFilter?(clause) == true
                    {
                        // Apply, then leave the pushed stack explicitly: any
                        // query mutation reconciles a path-bound stack back
                        // to its root, so staying put is not an option.
                        // The sheet closes; the chip lands on the dashboard.
                        appliedFilterTick += 1
                        dismissSheet()
                    } else {
                        localError = "This filter conflicts with an active filter."
                    }
                }
                .accessibilityIdentifier("\(prefix)-filter")
                .sensoryFeedback(.success, trigger: appliedFilterTick)
            }
            if let url = openTarget {
                Button("Open link") { openURL(url) }
                    .accessibilityIdentifier("\(prefix)-open")
            }
            if let localError {
                Text(localError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(prefix)-filter-error")
            }
        }
        .navigationTitle(row.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
                    .accessibilityIdentifier("\(prefix)-detail-done")
            }
        }
        .accessibilityIdentifier("\(prefix)-detail")
    }

    private func dimensionLabel(_ dimension: FilterDimension) -> String {
        dimensionName(dimension).lowercased()
    }
}
