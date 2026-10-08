import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@Suite("pages families (05.4)")
@MainActor
struct PagesTests {
    @Test("page families carry their verified columns and dimensions")
    func pageContracts() {
        #expect(ReportDefinition.pages.columns == [.visitors, .pageviews, .bounceRate, .timeOnPage, .scrollDepth, .percentage])
        #expect(ReportDefinition.entryPages.columns == [.visitors, .visits, .bounceRate, .visitDuration, .percentage])
        #expect(ReportDefinition.exitPages.columns == [.visitors, .visits, .exitRate, .percentage])
        #expect(ReportDefinition.pages.filterDimension == .page)
        #expect(ReportDefinition.entryPages.filterDimension == .entryPage)
        #expect(ReportDefinition.exitPages.filterDimension == .exitPage)
        #expect(ReportDefinition.pages.pagePaths)
        #expect(ReportDefinition.entryPages.pagePaths)
        #expect(ReportDefinition.exitPages.pagePaths)
        #expect(!ReportDefinition.pages.allowsExternalOpen)
        #expect(ReportDefinition.pages.drilldown(BreakdownRow(name: "/pricing", metrics: [.visitors: .count(1)])) == nil)
        #expect(breakdownDefinition(for: .pages).title == "Pages")
        #expect(breakdownDefinition(for: .entryPages).title == "Entry pages")
        #expect(breakdownDefinition(for: .exitPages).title == "Exit pages")
    }

    @Test("page filter clauses use page dimensions")
    func pageFilterClauses() {
        #expect(ReportDefinition.pages.filterClause(for: "/pricing") == FilterClause(
            dimension: .page, op: .is_, values: [.text("/pricing")]
        ))
        #expect(ReportDefinition.entryPages.filterClause(for: "/")?.dimension == .entryPage)
        #expect(ReportDefinition.exitPages.filterClause(for: "/")?.dimension == .exitPage)
    }

    @Test("mock pages keep null engagement and distinct entrance counts")
    func mockPageShapes() {
        let pages = MockBreakdownProviders.dataset(for: .pages)
        #expect(pages.count == 60)
        #expect(pages.allSatisfy { $0.metrics[.pageviews] != nil && $0.metrics[.visitors] != nil })
        #expect(pages.contains { $0.metrics[.timeOnPage] == .unavailable(.null) })
        #expect(pages.contains { $0.metrics[.scrollDepth] == .unavailable(.null) })
        #expect(pages.contains { $0.metrics[.timeOnPage]?.hasNumber == true })

        let entries = MockBreakdownProviders.dataset(for: .entryPages)
        #expect(entries.count == 40)
        // Entrances ride visits and never equal pageviews: no pageviews key.
        #expect(entries.allSatisfy { $0.metrics[.visits] != nil && $0.metrics[.pageviews] == nil })

        let exits = MockBreakdownProviders.dataset(for: .exitPages)
        #expect(exits.count == 40)
        #expect(exits.allSatisfy { $0.metrics[.exitRate] != nil && $0.metrics[.visits] != nil })
    }
}
