import AnalyticsCore
import Foundation

/// Drilldown destination: a child report kind plus an optional filter
/// clause baked into the child's query. Route-based drilldowns (referrer
/// URLs) carry no filter; hierarchy drilldowns without their own route
/// (channel → sources) carry one.
public struct DrillTarget: Hashable, Sendable {
    public let kind: ReportKind
    public let title: String
    public let filter: FilterClause?

    public init(kind: ReportKind, title: String, filter: FilterClause? = nil) {
        self.kind = kind
        self.title = title
        self.filter = filter
    }
}

/// One breakdown family: wire kind, ordered display columns, and the
/// interactions the server supports for it. `supportsSearch` is a verified
/// capability, not a guess: live probes 2026-10-07 proved the server ignores
/// `search` for sources/channels/pages/referrer-drilldown, so every v1
/// family keeps it false (unit-tested plumbing only). `drilldown` maps a row
/// name to its child target; nil means leaf rows (detail sheet instead of
/// navigation). `filterDimension` is the query dimension a row filters by
/// (nil = not filterable).
public struct ReportDefinition: Sendable {
    public let kind: ReportKind
    public let title: String
    public let columns: [MetricID]
    public let defaultSort: ReportSort?
    public let supportsSearch: Bool
    public let drilldown: @Sendable (BreakdownRow) -> DrillTarget?
    public let filterDimension: FilterDimension?
    /// Whether row names are hostnames/URLs that may offer an Open action
    /// (through ExternalLinkGate). Source/channel names are not URLs and
    /// never open, even when they look like hosts.
    public let allowsExternalOpen: Bool
    /// Whether row names are site-relative paths ("/pricing") opened
    /// against the query's site domain. Never combined with URL names.
    public let pagePaths: Bool

    public init(
        kind: ReportKind,
        title: String,
        columns: [MetricID],
        defaultSort: ReportSort? = nil,
        supportsSearch: Bool = false,
        filterDimension: FilterDimension? = nil,
        allowsExternalOpen: Bool = false,
        pagePaths: Bool = false,
        drilldown: @escaping @Sendable (BreakdownRow) -> DrillTarget? = { _ in nil }
    ) {
        self.kind = kind
        self.title = title
        self.columns = columns
        self.defaultSort = defaultSort
        self.supportsSearch = supportsSearch
        self.filterDimension = filterDimension
        self.allowsExternalOpen = allowsExternalOpen
        self.pagePaths = pagePaths
        self.drilldown = drilldown
    }

    /// Proof family for 05.1: sources with visitors + share, mock-honored
    /// search, leaf rows. Real families below; live search support is
    /// verified in 05.5.
    public static var sourcesProof: ReportDefinition {
        ReportDefinition(kind: .sources, title: "Sources", columns: [.visitors, .percentage], supportsSearch: true)
    }

    /// ACQ-01: ranked channels with engagement; drilldown shows the
    /// channel's sources (no channel route exists — hierarchy rides a
    /// channel filter on the sources family, live-verified shapes).
    public static var channels: ReportDefinition {
        ReportDefinition(
            kind: .channels,
            title: "Channels",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .channel,
            drilldown: { row in
                DrillTarget(
                    kind: .sources,
                    title: "Sources · \(row.name)",
                    filter: FilterClause(dimension: .channel, op: .is_, values: [.text(row.name)])
                )
            }
        )
    }

    /// ACQ-02: sources with engagement; every row drills to its referring
    /// URLs (live-proven for referrer-backed and campaign sources; the
    /// degenerate Direct row answers itself; "Google" hits the parked
    /// GSC branch and surfaces its typed error honestly).
    /// The Google row instead opens Search terms: CE serves Google search
    /// queries (with GSC position/CTR/impressions when connected) through
    /// the `referrers/Google` route, mirroring the dashboard.
    public static var sources: ReportDefinition {
        ReportDefinition(
            kind: .sources,
            title: "Sources",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .source,
            drilldown: { row in
                if row.name.trimmingCharacters(in: .whitespacesAndNewlines) == "Google" {
                    return DrillTarget(kind: .searchTerms, title: "Search terms")
                }
                return DrillTarget(kind: .referrerDrilldown(referrer: row.name), title: row.name)
            }
        )
    }

    /// ACQ-02b: Google search terms (GSC-backed when the site connects
    /// Search Console; plain visitor counts otherwise). Live-shaped columns
    /// are visitors plus GSC position/CTR/impressions; the server sends no
    /// engagement or share columns here. Leaf rows: terms are not URLs and
    /// carry no filter dimension.
    public static var searchTerms: ReportDefinition {
        ReportDefinition(
            kind: .searchTerms, title: "Search terms",
            columns: [.visitors, .impressions, .ctr, .position]
        )
    }

    /// ACQ-03: referring URLs for one source; leaf rows (no deeper route).
    /// Row names are real referring URLs/hostnames, so Open actions apply.
    public static func referrerDrilldown(name: String) -> ReportDefinition {
        ReportDefinition(
            kind: .referrerDrilldown(referrer: name),
            title: name,
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .referrer,
            allowsExternalOpen: true
        )
    }

    /// ACQ-04..08: the five UTM families. Each wires its own verified route
    /// and dimension with no alias assumptions (medium/source/campaign/
    /// term/content share the source-family columns, live-verified). Leaf
    /// rows: no UTM drilldown route exists. Names are tag values, not URLs.
    public static var utmMediums: ReportDefinition {
        ReportDefinition(
            kind: .utmMediums, title: "UTM Medium",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .utmMedium
        )
    }

    public static var utmSources: ReportDefinition {
        ReportDefinition(
            kind: .utmSources, title: "UTM Source",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .utmSource
        )
    }

    public static var utmCampaigns: ReportDefinition {
        ReportDefinition(
            kind: .utmCampaigns, title: "UTM Campaign",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .utmCampaign
        )
    }

    public static var utmTerms: ReportDefinition {
        ReportDefinition(
            kind: .utmTerms, title: "UTM Term",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .utmTerm
        )
    }

    public static var utmContents: ReportDefinition {
        ReportDefinition(
            kind: .utmContents, title: "UTM Content",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .utmContent
        )
    }

    /// All five UTM definitions in dashboard order.
    public static var utmFamilies: [ReportDefinition] {
        [.utmMediums, .utmSources, .utmCampaigns, .utmTerms, .utmContents]
    }

    /// PAGE-01: pages with contextual engagement. time_on_page/scroll_depth
    /// are frequently null (unavailable) — shown as gaps, never zeros.
    /// Row names are site-relative paths; Open builds on the site domain.
    public static var pages: ReportDefinition {
        ReportDefinition(
            kind: .pages, title: "Pages",
            columns: [.visitors, .pageviews, .bounceRate, .timeOnPage, .scrollDepth, .percentage],
            filterDimension: .page,
            pagePaths: true
        )
    }

    /// PAGE-02: entry pages. Entrances ride `visits` contextually and are
    /// never equal to pageviews by construction (distinct server columns).
    public static var entryPages: ReportDefinition {
        ReportDefinition(
            kind: .entryPages, title: "Entry pages",
            columns: [.visitors, .visits, .bounceRate, .visitDuration, .percentage],
            filterDimension: .entryPage,
            pagePaths: true
        )
    }

    /// PAGE-03: exit pages with the server-computed exit rate denominator.
    public static var exitPages: ReportDefinition {
        ReportDefinition(
            kind: .exitPages, title: "Exit pages",
            columns: [.visitors, .visits, .exitRate, .percentage],
            filterDimension: .exitPage,
            pagePaths: true
        )
    }

    /// GEO-01: countries with flag + ISO codes. The server exposes only
    /// visitors and share (pinned upstream countries_test.exs:19-36) —
    /// no engagement columns. Unknown codes are dropped server-side, never
    /// shown as rows. Drilldown lists the country's regions.
    public static var countries: ReportDefinition {
        ReportDefinition(
            kind: .countries, title: "Countries",
            columns: [.visitors, .percentage],
            filterDimension: .country,
            drilldown: { row in
                DrillTarget(
                    kind: .regions,
                    title: "Regions · \(row.name)",
                    filter: FilterClause(
                        dimension: .country, op: .is_,
                        values: [.text(row.code ?? row.name)]
                    )
                )
            }
        )
    }

    /// GEO-02: regions with subdivision codes. No country filter required
    /// server-side (pinned upstream regions_test.exs:38); drilldown lists
    /// the region's cities.
    public static var regions: ReportDefinition {
        ReportDefinition(
            kind: .regions, title: "Regions",
            columns: [.visitors, .percentage],
            filterDimension: .region,
            drilldown: { row in
                DrillTarget(
                    kind: .cities,
                    title: "Cities · \(row.name)",
                    filter: FilterClause(
                        dimension: .region, op: .is_,
                        values: [.text(row.code ?? row.name)]
                    )
                )
            }
        )
    }

    /// GEO-03: cities keyed by integer geoname IDs (decoded tolerantly to
    /// strings). Missing/zero cities are dropped server-side (pinned
    /// upstream cities_test.exs:73-98). Leaf rows.
    public static var cities: ReportDefinition {
        ReportDefinition(
            kind: .cities, title: "Cities",
            columns: [.visitors, .percentage],
            filterDimension: .city
        )
    }

    /// DEV-01: device/screen classes. `detailed=true` adds engagement
    /// (pinned upstream screen_sizes_test.exs:38-59).
    public static var screenSizes: ReportDefinition {
        ReportDefinition(
            kind: .screenSizes, title: "Devices",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .screen
        )
    }

    /// DEV-02: browsers. Live local fixture proves `{name, visitors,
    /// percentage}` only (no engagement keys with `detailed=true`).
    /// Drilldown lists the browser's versions through the separate
    /// versions route with a parent filter (pinned upstream
    /// browsers_test.exs:442).
    public static var browsers: ReportDefinition {
        ReportDefinition(
            kind: .browsers, title: "Browsers",
            columns: [.visitors, .percentage],
            filterDimension: .browser,
            drilldown: { row in
                DrillTarget(
                    kind: .browserVersions,
                    title: "Versions · \(row.name)",
                    filter: FilterClause(dimension: .browser, op: .is_, values: [.text(row.name)])
                )
            }
        )
    }

    /// DEV-02 versions: version-only names with engagement under
    /// `detailed=true` (pinned upstream browsers_test.exs:468-492).
    /// Leaf rows.
    public static var browserVersions: ReportDefinition {
        ReportDefinition(
            kind: .browserVersions, title: "Browser versions",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .browserVersion
        )
    }

    /// DEV-03: operating systems. Columns mirror browsers pending live
    /// proof (os-family live parity queued with the throwaway round-trip).
    /// Drilldown lists the OS versions through the separate versions route
    /// with a parent filter (pinned upstream
    /// operating_systems_test.exs:348).
    public static var operatingSystems: ReportDefinition {
        ReportDefinition(
            kind: .operatingSystems, title: "Operating systems",
            columns: [.visitors, .percentage],
            filterDimension: .os,
            drilldown: { row in
                DrillTarget(
                    kind: .operatingSystemVersions,
                    title: "Versions · \(row.name)",
                    filter: FilterClause(dimension: .os, op: .is_, values: [.text(row.name)])
                )
            }
        )
    }

    /// DEV-03 versions (pinned upstream
    /// operating_systems_test.exs:391-400). Leaf rows.
    public static var operatingSystemVersions: ReportDefinition {
        ReportDefinition(
            kind: .operatingSystemVersions, title: "OS versions",
            columns: [.visitors, .bounceRate, .visitDuration, .percentage],
            filterDimension: .osVersion
        )
    }

    /// GOAL-01: goal conversions. `events` is nil for scroll goals
    /// (upstream conversions_test.exs:131-144) — rendered as a gap, never
    /// zero. No pagination server-side; the full list renders.
    public static var conversions: ReportDefinition {
        ReportDefinition(
            kind: .conversions, title: "Goal conversions",
            columns: [.visitors, .events, .conversionRate],
            filterDimension: .goal
        )
    }

    /// PROP-01: values for one property key. Goal-filtered reads swap
    /// `percentage` for `conversion_rate` server-side (upstream
    /// custom_prop_breakdown_test.exs:176-182); missing values arrive as
    /// literal `(none)` rows. Filter clauses carry the key
    /// (`event:props:<key>`).
    public static func customPropValues(key: String) -> ReportDefinition {
        ReportDefinition(
            kind: .customPropValues(key: key), title: key,
            columns: [.visitors, .events, .percentage, .conversionRate],
            filterDimension: .props
        )
    }

    /// Filter clause applying this family's dimension for one row value.
    /// Geo families filter by stable code (ISO-2, subdivision, geoname id),
    /// never the display name; name-backed families use the row name.
    /// Property families carry their key (`event:props:<key>`).
    public func filterClause(for name: String, code: String? = nil) -> FilterClause? {
        guard let filterDimension else { return nil }
        let propertyKey: String? = if case .customPropValues(let key) = kind { key } else { nil }
        return FilterClause(
            dimension: filterDimension, propertyKey: propertyKey,
            op: .is_, values: [.text(code ?? name)]
        )
    }

    /// Stable accessibility prefix for this family's views. Same-kind full
    /// views never co-display, so kind scoping keeps every id unique.
    /// Drilldown views share one kind-level prefix: pushed views cover
    /// their parents, so no two drilldown reports ever match together.
    public var idPrefix: String {
        if case .referrerDrilldown = kind { return "breakdown-referrers-drilldown" }
        if case .searchTerms = kind { return "breakdown-search-terms" }
        return "breakdown-\(kind.path().replacingOccurrences(of: "/", with: "-"))"
    }
}

/// Resolves a drill target kind to its family definition, with an
/// optional title override for hierarchy children ("Sources · X").
public func breakdownDefinition(for kind: ReportKind, title: String? = nil) -> ReportDefinition {
    switch kind {
    case .sources:
        let base = ReportDefinition.sources
        return ReportDefinition(
            kind: .sources, title: title ?? base.title, columns: base.columns,
            filterDimension: base.filterDimension,
            allowsExternalOpen: base.allowsExternalOpen,
            drilldown: base.drilldown
        )
    case .channels:
        return .channels
    case .searchTerms:
        return .searchTerms
    case .referrerDrilldown(let name):
        return .referrerDrilldown(name: name)
    case .utmMediums:
        return .utmMediums
    case .utmSources:
        return .utmSources
    case .utmCampaigns:
        return .utmCampaigns
    case .utmTerms:
        return .utmTerms
    case .utmContents:
        return .utmContents
    case .pages:
        return .pages
    case .entryPages:
        return .entryPages
    case .exitPages:
        return .exitPages
    case .countries:
        return .countries
    case .regions:
        // Hierarchy children keep their filtered title ("Regions · Iran").
        if let title {
            let base = ReportDefinition.regions
            return ReportDefinition(
                kind: .regions, title: title, columns: base.columns,
                filterDimension: base.filterDimension,
                drilldown: base.drilldown
            )
        }
        return .regions
    case .cities:
        if let title {
            let base = ReportDefinition.cities
            return ReportDefinition(
                kind: .cities, title: title, columns: base.columns,
                filterDimension: base.filterDimension,
                drilldown: base.drilldown
            )
        }
        return .cities
    case .screenSizes:
        return .screenSizes
    case .browsers:
        return .browsers
    case .browserVersions:
        if let title {
            let base = ReportDefinition.browserVersions
            return ReportDefinition(
                kind: .browserVersions, title: title, columns: base.columns,
                filterDimension: base.filterDimension,
                drilldown: base.drilldown
            )
        }
        return .browserVersions
    case .operatingSystems:
        return .operatingSystems
    case .conversions:
        return .conversions
    case .customPropValues(let key):
        return .customPropValues(key: key)
    case .operatingSystemVersions:
        if let title {
            let base = ReportDefinition.operatingSystemVersions
            return ReportDefinition(
                kind: .operatingSystemVersions, title: title, columns: base.columns,
                filterDimension: base.filterDimension,
                drilldown: base.drilldown
            )
        }
        return .operatingSystemVersions
    default:
        return ReportDefinition(kind: kind, title: title ?? kind.path(), columns: [.visitors])
    }
}

/// Copies a query with one extra filter clause appended (hierarchy
/// drilldowns). Validation of the merged set happens at load time.
public func breakdownQuery(_ query: DashboardQuery, adding filter: FilterClause?) -> DashboardQuery {
    guard let filter else { return query }
    return DashboardQuery(
        accountID: query.accountID,
        siteID: query.siteID,
        period: query.period,
        periodDate: query.periodDate,
        comparison: query.comparison,
        matchDayOfWeek: query.matchDayOfWeek,
        filters: FilterExpression(clauses: query.filters.clauses + [filter]),
        includeImported: query.includeImported,
        interval: query.interval,
        selectedMetric: query.selectedMetric,
        timeZone: query.timeZone
    )
}

/// One breakdown report's lifecycle: server-side sort/search, limit/page
/// accumulation, and drilldown-neutral row storage.
///
/// Rules (adapted from 04.1 for multi-page reports):
/// - Sort and search always go through the server (`order_by`/`search`);
///   rows are appended in served order and never re-sorted client-side, so
///   tied values keep their stable server sequence.
/// - `hasMore` is derived from page fullness: a short page ends the report;
///   a full page keeps `hasMore` true, and the first empty page after it
///   closes the report without touching loaded rows (empty last page).
/// - Every fetch carries a generation + request key; late or superseded
///   results never publish. A concurrent identical request is deduplicated.
/// - `cancel` keeps loaded rows (initial load cancels back to idle).
/// - `completeness` exposes coverage for later export phases; export UI
///   itself is out of scope here.
@MainActor
@Observable
public final class BreakdownModel {
    public typealias Loader = @Sendable (BreakdownRequest, Date) async throws -> ReportEnvelope<BreakdownPage>

    public private(set) var query: DashboardQuery
    public let definition: ReportDefinition
    public let pageSize: Int
    public private(set) var rows: [BreakdownRow] = []
    public private(set) var state: BreakdownState = .idle
    public private(set) var warnings: [ReportWarning] = []
    public private(set) var sort: ReportSort?
    public private(set) var search: String?
    public private(set) var page: Int = 0
    public private(set) var hasMore: Bool = true

    /// Coverage for export phases: loaded row count plus whether the server
    /// holds more pages.
    public var completeness: (loaded: Int, hasMore: Bool) { (rows.count, hasMore) }

    private let loader: Loader
    private let clock: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var loadingKey: String?
    private var loadTask: Task<Void, Never>?

    public init(
        definition: ReportDefinition,
        query: DashboardQuery,
        pageSize: Int = Pagination.default.limit,
        sort: ReportSort? = nil,
        loader: @escaping Loader,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.definition = definition
        self.query = query
        self.pageSize = max(1, pageSize)
        self.sort = sort ?? definition.defaultSort
        self.loader = loader
        self.clock = clock
    }

    /// Retargets the report (period/filter edits). Resets and reloads only
    /// when the query actually changed.
    public func updateQuery(_ query: DashboardQuery, today: Date? = nil) async {
        guard query != self.query else { return }
        self.query = query
        await resetAndLoad(today: today)
    }

    public func load(today: Date? = nil) async {
        await resetAndLoad(today: today)
    }

    public func loadMore(today: Date? = nil) async {
        guard hasMore, loadingKey == nil else { return }
        await fetch(page: page + 1, today: today ?? clock(), replacing: false)
    }

    public func setSort(_ sort: ReportSort?, today: Date? = nil) async {
        guard sort != self.sort else { return }
        self.sort = sort
        await resetAndLoad(today: today)
    }

    /// Server search where the family supports it; ignored otherwise (the
    /// view hides the field when unsupported).
    public func setSearch(_ search: String?, today: Date? = nil) async {
        guard definition.supportsSearch else { return }
        let normalized = (search ?? "").isEmpty ? nil : search
        guard normalized != self.search else { return }
        self.search = normalized
        await resetAndLoad(today: today)
    }

    public func retry(today: Date? = nil) async {
        if rows.isEmpty {
            await resetAndLoad(today: today)
        } else if hasMore {
            await fetch(page: page + 1, today: today ?? clock(), replacing: false)
        }
    }

    public func cancel() {
        loadTask?.cancel()
        loadTask = nil
        loadingKey = nil
        if case .loading = state {
            state = rows.isEmpty ? .idle : .loaded
        }
    }

    // MARK: - Internals

    private func resetAndLoad(today: Date?) async {
        page = 0
        hasMore = true
        rows = []
        warnings = []
        await fetch(page: 1, today: today ?? clock(), replacing: true)
    }

    private func fetch(page: Int, today: Date, replacing: Bool) async {
        let request = BreakdownRequest(
            query: query,
            kind: definition.kind,
            sort: sort,
            search: search,
            pagination: Pagination(limit: pageSize, page: page)
        )
        let key = Self.key(for: request, queryID: (try? QueryID.compute(for: query, today: today))?.rawValue ?? "")
        if loadingKey == key { return } // dedup identical in-flight request
        loadTask?.cancel()
        generation &+= 1
        let myGeneration = generation
        loadingKey = key
        state = .loading
        let loader = loader
        loadTask = Task {
            do {
                let envelope = try await loader(request, today)
                await self.publish(envelope.value.rows, warnings: envelope.warnings, page: page, replacing: replacing, key: key, generation: myGeneration)
            } catch is CancellationError {
                // Silent: superseding fetch or explicit cancel owns the state.
            } catch {
                await self.publishFailure(ReportLoadError.wrap(error), key: key, generation: myGeneration)
            }
        }
        await loadTask?.value
    }

    private func publish(_ newRows: [BreakdownRow], warnings: [ReportWarning], page: Int, replacing: Bool, key: String, generation: UInt64) {
        guard generation == self.generation, loadingKey == key else { return }
        loadingKey = nil
        if replacing {
            rows = newRows
        } else {
            rows += newRows
        }
        self.warnings = warnings
        self.page = page
        // A short page ends the report; a full page may still be followed by
        // an empty one, which then closes it without touching loaded rows.
        hasMore = newRows.count >= pageSize
        state = .loaded
    }

    private func publishFailure(_ error: ReportLoadError, key: String, generation: UInt64) {
        guard generation == self.generation, loadingKey == key else { return }
        loadingKey = nil
        state = .failed(error)
    }

    private static func key(for request: BreakdownRequest, queryID: String) -> String {
        let sort = request.sort.map { "\($0.key.wireString)|\($0.direction.rawValue)" } ?? "-"
        return [queryID, request.kind.path(), sort, request.search ?? "-", "\(request.pagination.limit)", "\(request.pagination.page)"].joined(separator: "/")
    }
}

/// Breakdown lifecycle states. Loaded rows stay visible under `.failed`;
/// the view chooses full-error vs inline-error by `rows.isEmpty`.
public enum BreakdownState: Sendable {
    case idle
    case loading
    case loaded
    case failed(ReportLoadError)
}

private extension SortKey {
    var wireString: String {
        switch self {
        case .metric(let metric): return metric.rawValue
        case .dimension(let name): return name
        }
    }
}
