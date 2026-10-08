import XCTest

/// Bootstrap smoke test: the app launches into its deterministic mock root.
@MainActor
final class SmokeTests: XCTestCase {
    func testMockLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-plausely-mock")
        app.launch()
        XCTAssertTrue(app.staticTexts["Mock"].waitForExistence(timeout: 15))
    }

    /// Live root with a wiped instance store renders the honest sign-in
    /// gate: server, email, password, and submit — never fake sites.
    func testLiveRootShowsLoginWhenNoInstances() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-plausely-live-reset")
        app.launch()
        let view = app.descendants(matching: .any)["login-view"]
        XCTAssertTrue(view.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["login-server"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["login-email"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["login-password"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["login-submit"].exists)
    }
}


/// Site shell against the deterministic 13-site mock directory: sidebar
/// selection, long names, detail/back, and instance switching.
@MainActor
final class SiteShellTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-plausely-mock-sites")
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testSiteSelectionDetailAndBack() throws {
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 15))
        // Long domain renders (truncation never drops the row)…
        let longDomain = "extremely-long-subdomain-name-for-truncation-testing-purposes.example.com"
        let longRow = element("site-row-\(longDomain)")
        XCTAssertTrue(longRow.waitForExistence(timeout: 15))
        longRow.tap()
        XCTAssertTrue(app.navigationBars[longDomain].waitForExistence(timeout: 15))
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("site-row-alpha-1.example.com").waitForExistence(timeout: 15))
        // …and a 13-site list keeps its tail reachable through search.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("beta-6")
        let tailRow = element("site-row-beta-6.example.org")
        XCTAssertTrue(tailRow.waitForExistence(timeout: 15))
        tailRow.tap()
        XCTAssertTrue(app.navigationBars["beta-6.example.org"].waitForExistence(timeout: 15))
    }

    func testInstanceSwitchChangesSites() throws {
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 15))
        XCTAssertTrue(element("site-row-alpha-1.example.com").waitForExistence(timeout: 15))
        // The instance menu is a native menu button titled by the account.
        element("owner@example.com").tap()
        app.descendants(matching: .any)["viewer@example.com"].firstMatch.tap()
        XCTAssertTrue(element("site-row-local.example").waitForExistence(timeout: 15))
        XCTAssertFalse(element("site-row-alpha-1.example.com").waitForExistence(timeout: 5))
    }

    private func openDetail() {
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 15))
        element("site-row-alpha-1.example.com").tap()
        XCTAssertTrue(app.navigationBars["alpha-1.example.com"].waitForExistence(timeout: 15))
    }

    private func menuOption(_ option: String) -> XCUIElement {
        app.descendants(matching: .any)[option].firstMatch
    }

    private func reveal(_ identifier: String, timeout: TimeInterval = 15) -> XCUIElement {
        let target = element(identifier)
        let deadline = Date().addingTimeInterval(timeout)
        while !target.exists, Date() < deadline {
            app.swipeUp()
        }
        // Cells rendered at the bottom edge (home-indicator zone) exist but
        // never receive taps until scrolled fully on-screen.
        let hittableDeadline = Date().addingTimeInterval(5)
        while target.exists, !target.isHittable, Date() < hittableDeadline {
            app.swipeUp()
        }
        return target
    }

    func testQueryToolbarPeriodsAndComparison() throws {
        openDetail()
        // Period presets rewrite the query; the menu label tracks state.
        element("Last 28 days").tap()
        menuOption("Last 7 days").tap()
        XCTAssertTrue(element("Last 7 days").waitForExistence(timeout: 15))
        element("Last 7 days").tap()
        menuOption("Yesterday").tap()
        XCTAssertTrue(element("Yesterday").waitForExistence(timeout: 15))
        // Comparisons apply with the weekday-alignment toggle…
        element("No comparison").tap()
        menuOption("Previous period").tap()
        XCTAssertTrue(element("Previous period").waitForExistence(timeout: 15))
        XCTAssertTrue(element("Match day of week").waitForExistence(timeout: 15))
        // …and realtime refuses comparisons with a typed message.
        element("Previous period").tap()
        menuOption("No comparison").tap()
        element("Yesterday").tap()
        menuOption("Realtime").tap()
        element("No comparison").tap()
        menuOption("Previous period").tap()
        XCTAssertTrue(element("Comparisons are off for realtime.").waitForExistence(timeout: 15))
    }

    func testFilterAddSuggestAndRemove() throws {
        openDetail()
        reveal("filter-add").tap()
        let valueField = element("clause-value")
        XCTAssertTrue(valueField.waitForExistence(timeout: 15))
        valueField.tap()
        valueField.typeText("Goo")
        // Suggestion from the provider completes the value.
        let suggestion = element("suggestion-Google")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15))
        suggestion.tap()
        XCTAssertTrue(element("clause-value-Google").waitForExistence(timeout: 15))
        element("clause-add").tap()
        XCTAssertTrue(element("Source is Google").waitForExistence(timeout: 15))
        // Removal drops the clause again.
        element("filter-remove-0").tap()
        XCTAssertFalse(element("Source is Google").waitForExistence(timeout: 5))
    }

    func testSegmentApplyAndRemove() throws {
        openDetail()
        XCTAssertTrue(reveal("segment-apply-7").waitForExistence(timeout: 15))
        element("segment-apply-7").tap()
        XCTAssertTrue(element("segment-applied-7").waitForExistence(timeout: 15))
        XCTAssertTrue(element("Operating system is iOS").waitForExistence(timeout: 15))
        element("segment-clear").tap()
        XCTAssertFalse(element("Operating system is iOS").waitForExistence(timeout: 5))
    }

    func testBreakdownSummaryToDetail() throws {
        openDetail()
        // Sources summary with show-all.
        XCTAssertTrue(reveal("breakdown-sources-summary-0").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-summary-4").exists)
        // Full report opens as a sheet (like the dashboard's expanded
        // modal), so drilldown pushes always have a stack on every
        // platform. Return via Done; the site detail never loses state.
        reveal("breakdown-sources-show-all").tap()
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        // Server sort Z–A puts Source 1500 first. The chip applies
        // asynchronously; poll the first row until the reload lands.
        reveal("sort-option-breakdown-sources-name-desc").tap()
        do {
            let first = element("breakdown-sources-row-0")
            let deadline = Date().addingTimeInterval(15)
            while !first.label.contains("Source 1500"), Date() < deadline { sleep(1) }
            XCTAssertTrue(first.label.contains("Source 1500"))
        }
        // Sources rows drill to referring URLs.
        element("breakdown-sources-row-0").tap()
        XCTAssertTrue(element("breakdown-referrers-drilldown-row-0").waitForExistence(timeout: 15))
        // Leaf detail: scroll the form to Filter, apply, and the sheet
        // closes (query mutations reset path-bound stacks, so the report
        // returns explicitly instead of staying put). The chip lands on
        // the dashboard query.
        element("breakdown-referrers-drilldown-row-0").tap()
        XCTAssertTrue(element("breakdown-referrers-drilldown-detail-name").waitForExistence(timeout: 15))
        do {
            let filter = element("breakdown-referrers-drilldown-filter")
            let deadline = Date().addingTimeInterval(15)
            var swipes = 0
            while !filter.isHittable, Date() < deadline, swipes < 8 {
                element("breakdown-referrers-drilldown-detail").swipeUp()
                swipes += 1
            }
            sleep(1)
        }
        element("breakdown-referrers-drilldown-filter").tap()
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        // The applied filter retargets every report: the channels summary
        // narrows to nothing in the mock set (no channel carries the
        // referrer tag), which proves end-to-end propagation without
        // hunting a chip through virtualized rows.
        do {
            let row = element("breakdown-channels-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testChannelsDrillToFilteredSources() throws {
        openDetail()
        XCTAssertTrue(reveal("breakdown-channels-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-channels-show-all").tap()
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-channels-row-0").waitForExistence(timeout: 15))
        let channel = element("breakdown-channels-row-0").label
        // Drilling a channel shows its filtered sources child. The mock set
        // attributes no sources to synthetic channels, so the child is
        // honestly empty with the filtered title.
        element("breakdown-channels-row-0").tap()
        XCTAssertTrue(app.navigationBars["Sources · \(channel)"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-empty").waitForExistence(timeout: 15))
        // Done returns through the stack; the site detail keeps its state.
        element("breakdown-sources-close").tap()
        XCTAssertTrue(element("breakdown-channels-row-0").waitForExistence(timeout: 15))
        element("breakdown-channels-close").tap()
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
    }

    private func menuButton(_ title: String) -> XCUIElement {
        // The metric Menu drops its accessibility id (it inherits the
        // ancestor's, like macOS Menus), so match the tappable Button by
        // title: card name texts are StaticTexts and never collide.
        app.descendants(matching: .button)[title].firstMatch
    }

    func testUtmHubToFilter() throws {
        openDetail()
        // UTM hub entry opens the family list sheet.
        XCTAssertTrue(reveal("breakdown-utm-hub").waitForExistence(timeout: 15))
        reveal("breakdown-utm-hub").tap()
        XCTAssertTrue(element("breakdown-hub-utm_mediums").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-hub-utm_contents").exists)
        // Mediums report; first row detail filters the dashboard query.
        element("breakdown-hub-utm_mediums").tap()
        XCTAssertTrue(element("breakdown-utm_mediums-row-0").waitForExistence(timeout: 15))
        element("breakdown-utm_mediums-row-0").tap()
        XCTAssertTrue(element("breakdown-utm_mediums-detail-name").waitForExistence(timeout: 15))
        sleep(1)
        do {
            let filter = element("breakdown-utm_mediums-filter")
            let deadline = Date().addingTimeInterval(15)
            var swipes = 0
            while !filter.isHittable, Date() < deadline, swipes < 8 {
                element("breakdown-utm_mediums-detail").swipeUp()
                swipes += 1
            }
            sleep(1)
        }
        element("breakdown-utm_mediums-filter").tap()
        XCTAssertFalse(element("breakdown-hub").waitForExistence(timeout: 5))
        // The applied filter retargets every report: sources narrow to
        // nothing in the mock set (no source carries the UTM tag), which
        // proves end-to-end propagation without hunting a chip through
        // virtualized rows.
        do {
            let row = element("breakdown-sources-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testPagesFilterAndOpen() throws {
        openDetail()
        // Pages summary with show-all.
        XCTAssertTrue(reveal("breakdown-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-pages-show-all").tap()
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-pages-row-0").waitForExistence(timeout: 15))
        // Leaf detail: null engagement renders as gaps (open check needs
        // a scroll), then Filter application closes the sheet.
        element("breakdown-pages-row-0").tap()
        XCTAssertTrue(element("breakdown-pages-detail-name").waitForExistence(timeout: 15))
        // Unavailable engagement renders as an explicit gap row, not zero.
        XCTAssertTrue(element("breakdown-pages-detail-time_on_page").exists)
        do {
            let open = element("breakdown-pages-open")
            let deadline = Date().addingTimeInterval(15)
            var swipes = 0
            while !open.exists, Date() < deadline, swipes < 8 {
                element("breakdown-pages-detail").swipeUp()
                swipes += 1
            }
        }
        XCTAssertTrue(element("breakdown-pages-open").waitForExistence(timeout: 15))
        do {
            let filter = element("breakdown-pages-filter")
            let deadline = Date().addingTimeInterval(15)
            var swipes = 0
            while !filter.isHittable, Date() < deadline, swipes < 8 {
                element("breakdown-pages-detail").swipeDown()
                swipes += 1
            }
            sleep(1)
        }
        element("breakdown-pages-filter").tap()
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        do {
            let row = element("breakdown-sources-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testEntryAndExitFilterFlows() throws {
        openDetail()
        // Entry pages: summary with show-all, full report, leaf detail,
        // filter application closes the sheet (mirrors the pages flow).
        XCTAssertTrue(reveal("breakdown-entry-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-entry-pages-show-all").tap()
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-entry-pages-row-0").waitForExistence(timeout: 15))
        // Entrances ride visits and never equal pageviews: the detail
        // exposes the visit count for the row.
        element("breakdown-entry-pages-row-0").tap()
        XCTAssertTrue(element("breakdown-entry-pages-detail-name").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-entry-pages-detail-visits").exists)
        do {
            let filter = element("breakdown-entry-pages-filter")
            let deadline = Date().addingTimeInterval(15)
            var swipes = 0
            while !filter.isHittable, Date() < deadline, swipes < 8 {
                element("breakdown-entry-pages-detail").swipeUp()
                swipes += 1
            }
            sleep(1)
        }
        element("breakdown-entry-pages-filter").tap()
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        // Exit pages keep their own flow after the entry filter lands: the
        // mock ignores the entry-page clause for other families, so the
        // exit summary still lists rows.
        XCTAssertTrue(reveal("breakdown-exit-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-exit-pages-show-all").tap()
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-exit-pages-row-0").waitForExistence(timeout: 15))
        element("breakdown-exit-pages-row-0").tap()
        XCTAssertTrue(element("breakdown-exit-pages-detail-name").waitForExistence(timeout: 15))
        // The server-computed exit rate renders on the detail.
        XCTAssertTrue(element("breakdown-exit-pages-detail-exit_rate").exists)
        do {
            let filter = element("breakdown-exit-pages-filter")
            let deadline = Date().addingTimeInterval(15)
            var swipes = 0
            while !filter.isHittable, Date() < deadline, swipes < 8 {
                element("breakdown-exit-pages-detail").swipeUp()
                swipes += 1
            }
            sleep(1)
        }
        element("breakdown-exit-pages-filter").tap()
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
    }

    func testComparisonBadgesAcrossWorkflows() throws {
        openDetail()
        // Previous-period comparison retargets every breakdown with
        // previous values and server deltas.
        element("No comparison").tap()
        menuOption("Previous period").tap()
        XCTAssertTrue(element("Previous period").waitForExistence(timeout: 15))
        // Compact summaries gain change badges on the primary column.
        XCTAssertTrue(reveal("breakdown-sources-summary-change-0-visitors").waitForExistence(timeout: 15))
        // The full report renders the comparison query's rows; its grid
        // cells are visual-only (LazyVGrid drops static cell content from
        // the AX tree, AX-proven 05.5), so the comparison payload is
        // proven through the leaf detail pushed from the full report.
        // Every report reloads at once under a new comparison, so the tap
        // can land mid-layout: retry until the sheet opens.
        do {
            let deadline = Date().addingTimeInterval(30)
            while !element("breakdown-full").exists, Date() < deadline {
                reveal("breakdown-sources-show-all").tap()
                sleep(1)
            }
        }
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-row-0").waitForExistence(timeout: 15))
        element("breakdown-sources-close").tap()
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        // Leaf details expose the previous value and the server delta.
        XCTAssertTrue(reveal("breakdown-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-pages-show-all").tap()
        XCTAssertTrue(element("breakdown-pages-row-0").waitForExistence(timeout: 15))
        element("breakdown-pages-row-0").tap()
        XCTAssertTrue(element("breakdown-pages-detail-visitors-change").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-pages-detail-visitors-comparison").exists)
    }

    func testOverviewCardsAndMetricSwitch() throws {
        openDetail()
        // Headline cards render the mock top-stats aggregates in order.
        XCTAssertTrue(reveal("overview-stat-visitors").waitForExistence(timeout: 15))
        XCTAssertTrue(element("overview-value-visitors").exists)
        XCTAssertTrue(element("overview-stat-bounce_rate").exists)
        // The chart inherits its ancestor id, so match its stable voice label.
        XCTAssertTrue(element("Unique visitors chart, 8 buckets").waitForExistence(timeout: 15))
        // Switching the chart metric reloads the series with its own identity.
        menuButton("Unique visitors").tap()
        menuOption("Total visits").tap()
        XCTAssertTrue(element("Total visits chart, 8 buckets").waitForExistence(timeout: 15))
        // The accessible table lists one row per bucket with exact values;
        // the nil bucket renders as an explicit gap, never a zero.
        let expectedRows = [
            "00:00, 14", "03:00, 28", "06:00, no data", "09:00, 56",
            "12:00, 70", "15:00, 84", "18:00, 98", "21:00, 112",
        ]
        for row in expectedRows {
            XCTAssertTrue(element(row).waitForExistence(timeout: 15))
        }
    }
}
