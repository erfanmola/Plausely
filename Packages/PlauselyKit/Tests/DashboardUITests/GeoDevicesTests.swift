import AnalyticsCore
import Foundation
import Testing

@testable import DashboardUI

@Suite("geography and device families (06)")
@MainActor
struct GeoDevicesTests {
    private func row(_ name: String, code: String? = nil) -> BreakdownRow {
        BreakdownRow(name: name, code: code, metrics: [.visitors: .count(10)])
    }

    @Test("geo families carry verified columns and code-based filters")
    func geoContracts() {
        #expect(ReportDefinition.countries.columns == [.visitors, .percentage])
        #expect(ReportDefinition.regions.columns == [.visitors, .percentage])
        #expect(ReportDefinition.cities.columns == [.visitors, .percentage])
        #expect(ReportDefinition.countries.filterDimension == .country)
        #expect(ReportDefinition.regions.filterDimension == .region)
        #expect(ReportDefinition.cities.filterDimension == .city)
        // Filters use stable codes, never display names.
        #expect(ReportDefinition.countries.filterClause(for: "Estonia", code: "EE") == FilterClause(
            dimension: .country, op: .is_, values: [.text("EE")]
        ))
        #expect(ReportDefinition.regions.filterClause(for: "Harjumaa", code: "EE-37")?.values == [.text("EE-37")])
        #expect(ReportDefinition.cities.filterClause(for: "Tallinn", code: "588409")?.values == [.text("588409")])
        #expect(ReportDefinition.cities.filterClause(for: "Tallinn")?.values == [.text("Tallinn")])
        #expect(ReportDefinition.countries.idPrefix == "breakdown-countries")
        #expect(ReportDefinition.regions.idPrefix == "breakdown-regions")
        #expect(ReportDefinition.cities.idPrefix == "breakdown-cities")
        #expect(!ReportDefinition.countries.supportsSearch)
    }

    @Test("country drills to regions, region drills to cities, cities are leaves")
    func geoDrilldowns() {
        let toRegions = ReportDefinition.countries.drilldown(row("United States", code: "US"))
        #expect(toRegions?.kind == .regions)
        #expect(toRegions?.title == "Regions · United States")
        #expect(toRegions?.filter == FilterClause(dimension: .country, op: .is_, values: [.text("US")]))

        let toCities = ReportDefinition.regions.drilldown(row("California", code: "US-CA"))
        #expect(toCities?.kind == .cities)
        #expect(toCities?.title == "Cities · California")
        #expect(toCities?.filter == FilterClause(dimension: .region, op: .is_, values: [.text("US-CA")]))

        #expect(ReportDefinition.cities.drilldown(row("Paris", code: "2988507")) == nil)
    }

    @Test("device families carry verified columns, versions drill by parent name")
    func deviceContracts() {
        #expect(ReportDefinition.browsers.columns == [.visitors, .percentage])
        #expect(ReportDefinition.operatingSystems.columns == [.visitors, .percentage])
        #expect(ReportDefinition.screenSizes.columns == [.visitors, .bounceRate, .visitDuration, .percentage])
        #expect(ReportDefinition.browserVersions.columns == [.visitors, .bounceRate, .visitDuration, .percentage])
        #expect(ReportDefinition.operatingSystemVersions.columns == [.visitors, .bounceRate, .visitDuration, .percentage])
        #expect(ReportDefinition.browsers.filterDimension == .browser)
        #expect(ReportDefinition.browserVersions.filterDimension == .browserVersion)
        #expect(ReportDefinition.operatingSystems.filterDimension == .os)
        #expect(ReportDefinition.operatingSystemVersions.filterDimension == .osVersion)
        #expect(ReportDefinition.screenSizes.filterDimension == .screen)
        #expect(ReportDefinition.screenSizes.drilldown(row("Desktop")) == nil)

        let versions = ReportDefinition.browsers.drilldown(row("Chrome"))
        #expect(versions?.kind == .browserVersions)
        #expect(versions?.title == "Versions · Chrome")
        #expect(versions?.filter == FilterClause(dimension: .browser, op: .is_, values: [.text("Chrome")]))

        let osVersions = ReportDefinition.operatingSystems.drilldown(row("Mac"))
        #expect(osVersions?.kind == .operatingSystemVersions)
        #expect(osVersions?.filter == FilterClause(dimension: .os, op: .is_, values: [.text("Mac")]))

        #expect(ReportDefinition.browserVersions.drilldown(row("119.0")) == nil)
        #expect(breakdownDefinition(for: .browserVersions, title: "Versions · Chrome").title == "Versions · Chrome")
        #expect(breakdownDefinition(for: .operatingSystems).title == "Operating systems")
        #expect(ReportDefinition.browsers.idPrefix == "breakdown-browsers")
        #expect(ReportDefinition.browserVersions.idPrefix == "breakdown-browser-versions")
        #expect(ReportDefinition.screenSizes.idPrefix == "breakdown-screen-sizes")
    }

    @Test("mock geo hierarchy filters like the server drilldowns")
    func mockHierarchyFiltering() async throws {
        let query = DashboardQuery(
            accountID: AccountID(),
            siteID: SiteID(domain: "shop.example"),
            period: .day,
            comparison: .off,
            filters: .empty,
            includeImported: false,
            interval: .hour,
            selectedMetric: .visitors,
            timeZone: TimeZone(identifier: "UTC")!
        )
        func load(kind: ReportKind, filter: FilterClause?) async throws -> [BreakdownRow] {
            var base = query
            if let filter {
                base = breakdownQuery(base, adding: filter)
            }
            let model = BreakdownModel(
                definition: breakdownDefinition(for: kind), query: base, pageSize: 50,
                loader: MockBreakdownProviders.loader
            )
            await model.load()
            return model.rows
        }
        // Country drilldown narrows regions to the country's subdivisions.
        let usRegions = try await load(
            kind: .regions,
            filter: FilterClause(dimension: .country, op: .is_, values: [.text("US")])
        )
        #expect(usRegions.map(\.code) == ["US-CA", "US-TX"])
        // Region drilldown narrows cities through the region linkage.
        let caCities = try await load(
            kind: .cities,
            filter: FilterClause(dimension: .region, op: .is_, values: [.text("US-CA")])
        )
        #expect(caCities.map(\.name) == ["San Francisco"])
        // Browser drilldown narrows versions to the parent brand.
        let chromeVersions = try await load(
            kind: .browserVersions,
            filter: FilterClause(dimension: .browser, op: .is_, values: [.text("Chrome")])
        )
        #expect(chromeVersions.map(\.name) == ["Chrome 119.0", "Chrome 118.0"])
        // Unfiltered families keep their full mock sets.
        #expect(try await load(kind: .countries, filter: nil).count == 12)
        #expect(try await load(kind: .screenSizes, filter: nil).count == 4)
    }
}
