import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@Suite("acquisition families (05.2)")
@MainActor
struct AcquisitionTests {
    @Test("channels drill to filtered sources; sources drill to referrer URLs")
    func drillTargets() {
        func row(_ name: String, code: String? = nil) -> BreakdownRow {
            BreakdownRow(name: name, code: code, metrics: [.visitors: .count(1)])
        }
        let channels = ReportDefinition.channels
        let target = channels.drilldown(row("Organic Search"))
        #expect(target?.kind == .sources)
        #expect(target?.title == "Sources · Organic Search")
        #expect(target?.filter == FilterClause(dimension: .channel, op: .is_, values: [.text("Organic Search")]))

        let sources = ReportDefinition.sources
        let drill = sources.drilldown(row("chatgpt.com"))
        #expect(drill?.kind == .referrerDrilldown(referrer: "chatgpt.com"))
        #expect(drill?.title == "chatgpt.com")
        #expect(drill?.filter == nil)

        let leaf = ReportDefinition.referrerDrilldown(name: "chatgpt.com")
        #expect(leaf.drilldown(row("bing.com/search")) == nil)
        #expect(leaf.allowsExternalOpen)
        #expect(leaf.filterDimension == .referrer)
    }

    @Test("family columns and filter dimensions match the live shapes")
    func familyContracts() {
        #expect(ReportDefinition.channels.columns == [.visitors, .bounceRate, .visitDuration, .percentage])
        #expect(ReportDefinition.sources.columns == [.visitors, .bounceRate, .visitDuration, .percentage])
        #expect(ReportDefinition.channels.filterDimension == .channel)
        #expect(ReportDefinition.sources.filterDimension == .source)
        #expect(ReportDefinition.sources.allowsExternalOpen == false)
        #expect(ReportDefinition.channels.allowsExternalOpen == false)
    }

    @Test("filter clauses carry the family dimension")
    func filterClauses() {
        #expect(ReportDefinition.sources.filterClause(for: "Google") == FilterClause(
            dimension: .source, op: .is_, values: [.text("Google")]
        ))
        #expect(ReportDefinition.channels.filterClause(for: "Email")?.dimension == .channel)
        #expect(ReportDefinition.referrerDrilldown(name: "x").filterClause(for: "bing.com/search")?.dimension == .referrer)
        let plain = ReportDefinition(kind: .sources, title: "Sources", columns: [.visitors])
        #expect(plain.filterClause(for: "Google") == nil)
    }

    @Test("referrer row clauses apply to the query model")
    func referrerClauseApplies() throws {
        let base = DashboardQuery(
            accountID: AccountID(),
            siteID: SiteID(domain: "shop.example"),
            period: .days28,
            comparison: .off,
            filters: .empty,
            includeImported: false,
            interval: .day,
            selectedMetric: .visitors,
            timeZone: TimeZone(identifier: "UTC")!
        )
        let model = QueryModel(base: base)
        let clause = try #require(ReportDefinition.referrerDrilldown(name: "x").filterClause(for: "bing.com/search"))
        #expect(model.addClause(clause))
        #expect(try #require(model.effective).filters.serialized() == #"[["is","visit:referrer",["bing.com/search"]]]"#)
    }

    @Test("definition resolver keeps family contracts with title overrides")
    func definitionResolver() {
        #expect(breakdownDefinition(for: .channels).columns == ReportDefinition.channels.columns)
        #expect(breakdownDefinition(for: .sources).title == "Sources")
        let child = breakdownDefinition(for: .sources, title: "Sources · Email")
        #expect(child.title == "Sources · Email")
        #expect(child.columns == ReportDefinition.sources.columns)
        #expect(child.drilldown(BreakdownRow(name: "Google", metrics: [.visitors: .count(1)]))?.kind == .referrerDrilldown(referrer: "Google"))
        #expect(breakdownDefinition(for: .referrerDrilldown(referrer: "x")).allowsExternalOpen)
    }

    @Test("query helper appends hierarchy filters without touching the base")
    func queryFilterMerge() {
        let base = DashboardQuery(
            accountID: AccountID(),
            siteID: SiteID(domain: "shop.example"),
            period: .days28,
            comparison: .off,
            filters: .empty,
            includeImported: false,
            interval: .day,
            selectedMetric: .visitors,
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(breakdownQuery(base, adding: nil) == base)
        let clause = FilterClause(dimension: .channel, op: .is_, values: [.text("Email")])
        let merged = breakdownQuery(base, adding: clause)
        #expect(merged.filters.clauses == [clause])
        #expect(merged.period == base.period && merged.siteID == base.siteID)
        #expect(base.filters.clauses.isEmpty)
    }

    @Test("view id prefixes stay unique per kind")
    func idPrefixes() {
        #expect(ReportDefinition.sources.idPrefix == "breakdown-sources")
        #expect(ReportDefinition.channels.idPrefix == "breakdown-channels")
        #expect(ReportDefinition.referrerDrilldown(name: "chatgpt.com").idPrefix == "breakdown-referrers-drilldown")
    }

    @Test("all five UTM families wire distinct routes and dimensions")
    func utmFamilies() {
        let families = ReportDefinition.utmFamilies
        #expect(families.count == 5)
        let kinds = families.map(\.kind)
        #expect(Set(kinds.map { $0.path() }).count == 5, "no aliased routes")
        let dims = families.compactMap(\.filterDimension)
        #expect(dims.count == 5)
        #expect(Set(dims.map { "\($0)" }).count == 5, "no aliased dimensions")
        #expect(families.allSatisfy { $0.columns == [.visitors, .bounceRate, .visitDuration, .percentage] })
        #expect(families.allSatisfy { !$0.allowsExternalOpen })
        #expect(families.allSatisfy {
            $0.drilldown(BreakdownRow(name: "anything", metrics: [.visitors: .count(1)])) == nil
        })
        #expect(families.allSatisfy { !$0.supportsSearch })
        #expect(ReportDefinition.utmMediums.filterClause(for: "email")?.dimension == .utmMedium)
        #expect(ReportDefinition.utmSources.filterClause(for: "newsletter")?.dimension == .utmSource)
        #expect(ReportDefinition.utmCampaigns.filterClause(for: "launch")?.dimension == .utmCampaign)
        #expect(ReportDefinition.utmTerms.filterClause(for: "a")?.dimension == .utmTerm)
        #expect(ReportDefinition.utmContents.filterClause(for: "top")?.dimension == .utmContent)
        #expect(breakdownDefinition(for: .utmCampaigns).title == "UTM Campaign")
        #expect(breakdownDefinition(for: .utmTerms).idPrefix == "breakdown-utm_terms")
    }

    @Test("mock UTM datasets carry family columns with ties")
    func mockUtmDatasets() {
        for kind in [ReportKind.utmMediums, .utmSources, .utmCampaigns, .utmTerms, .utmContents] {
            let rows = MockBreakdownProviders.dataset(for: kind)
            #expect(rows.count == 40)
            #expect(rows.allSatisfy {
                $0.metrics[.visitors] != nil && $0.metrics[.bounceRate] != nil &&
                    $0.metrics[.visitDuration] != nil && $0.metrics[.percentage] != nil
            })
        }
    }
    func mockDatasets() {
        let channels = MockBreakdownProviders.dataset(for: .channels)
        #expect(channels.count == 1500)
        #expect(channels.allSatisfy { $0.metrics[.visitors] != nil && $0.metrics[.bounceRate] != nil })
        let drill = MockBreakdownProviders.dataset(for: .referrerDrilldown(referrer: "chatgpt.com"))
        #expect(drill.count == 12)
        #expect(drill.allSatisfy { ExternalLinkGate.url(for: $0.name) != nil })
    }

    @Test("external gate opens web URLs only")
    func externalGate() {
        #expect(ExternalLinkGate.url(for: "https://example.com/page?q=1")?.absoluteString == "https://example.com/page?q=1")
        #expect(ExternalLinkGate.url(for: "http://example.com")?.scheme == "http")
        #expect(ExternalLinkGate.url(for: "chatgpt.com")?.absoluteString == "https://chatgpt.com")
        #expect(ExternalLinkGate.url(for: "HTTPS://EXAMPLE.COM")?.host?.lowercased() == "example.com")
        #expect(ExternalLinkGate.url(for: "example.com:8080/path")?.absoluteString == "https://example.com:8080/path")
        #expect(ExternalLinkGate.url(for: "javascript:alert(1)") == nil)
        #expect(ExternalLinkGate.url(for: "JaVaScRiPt:alert(1)") == nil)
        #expect(ExternalLinkGate.url(for: "data:text/html,<h1>x</h1>") == nil)
        #expect(ExternalLinkGate.url(for: "file:///etc/passwd") == nil)
        #expect(ExternalLinkGate.url(for: "myapp://open") == nil)
        #expect(ExternalLinkGate.url(for: "ftp://example.com/f") == nil)
        #expect(ExternalLinkGate.url(for: "//example.com/path") == nil)
        #expect(ExternalLinkGate.url(for: "Direct / None") == nil)
        #expect(ExternalLinkGate.url(for: "") == nil)
        #expect(ExternalLinkGate.url(for: "   ") == nil)
        #expect(ExternalLinkGate.url(for: "https://") == nil)
        #expect(ExternalLinkGate.url(for: "/pricing") == nil)
    }
}
