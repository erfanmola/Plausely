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
        XCTAssertTrue(app.windows.count > 0, "no windows; app state: \(app.debugDescription.prefix(2000))")
        let view = app.descendants(matching: .any)["login-view"]
        XCTAssertTrue(view.waitForExistence(timeout: 20), app.debugDescription)
        // macOS propagates the container id onto every Form control
        // (AX-proven: fields carry identifier 'login-view' with no title),
        // so match by control type, order, and button label.
        XCTAssertTrue(app.textFields.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.count, 2)
        XCTAssertTrue(app.secureTextFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["Sign In"].exists)
    }
}

/// macOS shell against the deterministic 13-site mock directory: sidebar
/// selection with simultaneously visible detail, team sections, and instance
/// switching. Multi-window isolation is proven at the model layer
/// (SiteSelectionTests.windowIsolation); every window owns its model.
@MainActor
final class SiteShellTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments.append("-plausely-mock-sites")
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testSidebarSelectionShowsDetail() throws {
        launch()
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 15))
        let longRow = element("site-row-extremely-long-subdomain-name-for-truncation-testing-purposes.example.com")
        XCTAssertTrue(longRow.waitForExistence(timeout: 15))
        element("site-row-beta-1.example.org").click()
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
        // Sidebar stays visible beside the detail on Mac.
        XCTAssertTrue(element("site-sidebar").exists)
    }

    func testInstanceSwitchChangesSites() throws {
        launch()
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 15))
        XCTAssertTrue(element("site-row-alpha-1.example.com").waitForExistence(timeout: 15))
        // The instance menu is a native menu button titled by the account;
        // on macOS it inherits the sidebar identifier, so match titles.
        menuButton("owner@example.com").click()
        menuItem("viewer@example.com").click()
        XCTAssertTrue(element("site-row-local.example").waitForExistence(timeout: 15))
        XCTAssertFalse(element("site-row-alpha-1.example.com").waitForExistence(timeout: 5))
    }

    private func openDetail() {
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 15))
        element("site-row-alpha-1.example.com").click()
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
    }

    /// Scrolls the detail list until the target is on-screen and hittable.
    /// macOS clicks never auto-scroll, list drags select instead of
    /// scrolling, and keys never reach the list under XCTest; clicking the
    /// scrollbar track pages down (one page per click) and never triggers
    /// app controls. Our targets always sit below the fold.
    /// Menu access with waits: on slower renderers the toolbar menus
    /// arrive after the detail does, so bare taps race and flake.
    private func menuButton(_ title: String, timeout: TimeInterval = 15) -> XCUIElement {
        let button = app.menuButtons[title]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "menu \(title)")
        return button
    }

    private func menuItem(_ title: String, timeout: TimeInterval = 15) -> XCUIElement {
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "menu item \(title)")
        return item
    }

    private func reveal(_ identifier: String, timeout: TimeInterval = 15) -> XCUIElement {
        let target = element(identifier)
        let deadline = Date().addingTimeInterval(timeout)
        var pages = 0
        while (!target.exists || !target.isHittable), Date() < deadline, pages < 8 {
            let bars = element("site-detail").scrollBars
            guard bars.count > 0 else { break }
            bars.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)).click()
            pages += 1
        }
        // Slow renderers may need a beat after the last page before the
        // frame settles; never hand back an unhittable target silently.
        while !target.isHittable, Date() < deadline { sleep(1) }
        return target
    }

    func testQueryToolbarPeriodsAndComparison() throws {
        launch()
        openDetail()
        menuButton("Last 28 days").click()
        menuItem("Last 7 days").click()
        XCTAssertTrue(app.menuButtons["Last 7 days"].waitForExistence(timeout: 15))
        menuButton("Last 7 days").click()
        menuItem("Yesterday").click()
        XCTAssertTrue(app.menuButtons["Yesterday"].waitForExistence(timeout: 15))
        menuButton("No comparison").click()
        menuItem("Previous period").click()
        XCTAssertTrue(app.menuButtons["Previous period"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("match-weekday-toggle").waitForExistence(timeout: 15))
        menuButton("Previous period").click()
        menuItem("No comparison").click()
        menuButton("Yesterday").click()
        menuItem("Realtime").click()
        menuButton("No comparison").click()
        menuItem("Previous period").click()
        XCTAssertTrue(element("Comparisons are off for realtime.").waitForExistence(timeout: 15))
    }

    func testFilterAddSuggestAndRemove() throws {
        launch()
        openDetail()
        element("filter-add").click()
        let valueField = element("clause-value")
        XCTAssertTrue(valueField.waitForExistence(timeout: 15))
        valueField.click()
        valueField.typeText("Goo")
        let suggestion = element("suggestion-Google")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15))
        suggestion.click()
        XCTAssertTrue(element("clause-value-Google").waitForExistence(timeout: 15))
        element("clause-add").click()
        XCTAssertTrue(element("Source is Google").waitForExistence(timeout: 15))
        element("filter-remove-0").click()
        XCTAssertFalse(element("Source is Google").waitForExistence(timeout: 5))
    }

    func testSegmentApplyAndRemove() throws {
        launch()
        openDetail()
        XCTAssertTrue(element("segment-apply-7").waitForExistence(timeout: 15))
        element("segment-apply-7").click()
        XCTAssertTrue(element("segment-applied-7").waitForExistence(timeout: 15))
        XCTAssertTrue(element("Operating system is iOS").waitForExistence(timeout: 15))
        element("segment-clear").click()
        XCTAssertFalse(element("Operating system is iOS").waitForExistence(timeout: 5))
    }

    func testBreakdownSummaryToDetail() throws {
        launch()
        openDetail()
        // Sources summary with show-all.
        XCTAssertTrue(reveal("breakdown-sources-summary-0").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-summary-4").exists)
        reveal("breakdown-sources-show-all").click()
        // The sheet opens (its container id is swallowed on macOS, so
        // match the sheet itself, then its content by control ids).
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        // Server sort Z–A puts Source 1500 first. The chip applies
        // asynchronously; poll the first row until the reload lands.
        element("sort-option-breakdown-sources-name-desc").click()
        do {
            let first = element("breakdown-sources-row-0")
            let deadline = Date().addingTimeInterval(15)
            while !first.label.contains("Source 1500"), Date() < deadline { sleep(1) }
            XCTAssertTrue(first.label.contains("Source 1500"))
        }
        // Sources rows drill to referring URLs.
        element("breakdown-sources-row-0").click()
        XCTAssertTrue(element("breakdown-referrers-drilldown-row-0").waitForExistence(timeout: 15))
        // Leaf detail: Filter application closes the sheet (query
        // mutations reset path-bound stacks, so the report returns
        // explicitly instead of staying put). The chip lands on the
        // dashboard query. (Inner detail ids are shadowed on macOS; the
        // pushed sheet window title carries the row name.)
        element("breakdown-referrers-drilldown-row-0").click()
        XCTAssertTrue(app.windows["referrer-1.example.com/article"].waitForExistence(timeout: 15))
        // Button ids shadow inside pushed Forms on macOS; match titles.
        XCTAssertTrue(app.descendants(matching: .button)["Open link"].waitForExistence(timeout: 15))
        app.descendants(matching: .button)["Filter by this referrer"].click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(element("Referrer is referrer-1.example.com/article").waitForExistence(timeout: 15))
    }

    func testChannelsDrillToFilteredSources() throws {
        launch()
        openDetail()
        XCTAssertTrue(reveal("breakdown-channels-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-channels-show-all").click()
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-channels-row-0").waitForExistence(timeout: 15))
        let channel = element("breakdown-channels-row-0").label
        // Drilling a channel shows its filtered sources child. The mock set
        // attributes no sources to synthetic channels, so the child is
        // honestly empty with the filtered title.
        element("breakdown-channels-row-0").click()
        XCTAssertTrue(app.windows["Sources · \(channel)"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-empty").waitForExistence(timeout: 15))
        // Done returns through the stack; the site detail keeps its state.
        element("breakdown-sources-close").click()
        XCTAssertTrue(element("breakdown-channels-row-0").waitForExistence(timeout: 15))
        sleep(1)
        element("breakdown-channels-close").click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
    }

    func testUtmHubToFilter() throws {
        launch()
        openDetail()
        // UTM hub entry opens the family list sheet.
        XCTAssertTrue(reveal("breakdown-utm-hub").waitForExistence(timeout: 15))
        reveal("breakdown-utm-hub").click()
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-hub-utm_mediums").waitForExistence(timeout: 15))
        // Mediums report; first row detail filters the dashboard query.
        // (Inner pushed ids shadow on macOS; match the sheet window title
        // for navigation and control titles for actions. The hub list
        // needs a layout beat before its rows accept clicks: resolve the
        // row fresh every poll, never reuse a stale snapshot.)
        do {
            let deadline = Date().addingTimeInterval(20)
            var tapped = false
            while !tapped, Date() < deadline {
                let candidate = element("breakdown-hub-utm_mediums")
                if candidate.isHittable { candidate.click(); tapped = true } else { sleep(1) }
            }
            XCTAssertTrue(tapped)
        }
        XCTAssertTrue(element("breakdown-utm_mediums-row-0").waitForExistence(timeout: 15))
        sleep(1)
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 10))
        sleep(2)
        element("breakdown-utm_mediums-row-0").click()
        sleep(2)
        // The push lands inside the sheet (sheets are not windows, so
        // match detail content, never the window title).
        XCTAssertTrue(element("breakdown-utm_mediums-detail").waitForExistence(timeout: 15))
        app.descendants(matching: .button)["Filter by this utm medium"].click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(element("UTM medium is UTM Medium 0001").waitForExistence(timeout: 15))
    }

    func testPagesFilterAndOpen() throws {
        launch()
        openDetail()
        // Pages summary with show-all.
        XCTAssertTrue(reveal("breakdown-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-pages-show-all").click()
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-pages-row-0").waitForExistence(timeout: 15))
        sleep(1)
        // Leaf detail pushes (null engagement + site Open inside).
        // Inner ids shadow on macOS; match the sheet window title.
        element("breakdown-pages-row-0").click()
        XCTAssertTrue(app.windows["/pricing"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .button)["Open link"].waitForExistence(timeout: 15))
        // Filter applies the page clause and closes the sheet; sources
        // narrow to nothing in the mock set.
        app.descendants(matching: .button)["Filter by this page"].click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        do {
            let row = element("breakdown-sources-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testEntryAndExitFilterFlows() throws {
        launch()
        openDetail()
        // Entry pages: summary with show-all, full report, leaf detail with
        // the visit (entrance) count, then filter application closes the
        // sheet. Inner detail ids shadow on macOS, so the pushed sheet
        // window title and control titles carry the assertions.
        XCTAssertTrue(reveal("breakdown-entry-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-entry-pages-show-all").click()
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-entry-pages-row-0").waitForExistence(timeout: 15))
        sleep(1)
        element("breakdown-entry-pages-row-0").click()
        XCTAssertTrue(app.windows["/pricing"].waitForExistence(timeout: 15))
        app.descendants(matching: .button)["Filter by this entry page"].click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(element("Entry page is /pricing").waitForExistence(timeout: 15))
        // Exit pages keep their own flow after the entry filter lands.
        // Every report reloads under the new filter, so the click can land
        // mid-layout: retry until the sheet opens.
        XCTAssertTrue(reveal("breakdown-exit-pages-summary-0").waitForExistence(timeout: 15))
        do {
            let deadline = Date().addingTimeInterval(30)
            while !app.sheets.element(boundBy: 0).exists, Date() < deadline {
                reveal("breakdown-exit-pages-show-all").click()
                sleep(1)
            }
        }
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-exit-pages-row-0").waitForExistence(timeout: 15))
        sleep(1)
        element("breakdown-exit-pages-row-0").click()
        XCTAssertTrue(app.windows["/pricing"].waitForExistence(timeout: 15))
        app.descendants(matching: .button)["Filter by this exit page"].click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
    }

    func testComparisonBadgesAcrossWorkflows() throws {
        launch()
        openDetail()
        // Previous-period comparison retargets every breakdown with
        // previous values and server deltas.
        menuButton("No comparison").click()
        menuItem("Previous period").click()
        XCTAssertTrue(app.menuButtons["Previous period"].waitForExistence(timeout: 15))
        // Compact summaries gain change badges on the primary column; the
        // full report renders the comparison query's rows.
        XCTAssertTrue(reveal("breakdown-sources-summary-change-0-visitors").waitForExistence(timeout: 15))
        reveal("breakdown-sources-show-all").click()
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-row-0").waitForExistence(timeout: 15))
        element("breakdown-sources-close").click()
        XCTAssertFalse(app.sheets.element(boundBy: 0).waitForExistence(timeout: 5))
        // Leaf details expose the server delta. Inner detail ids shadow on
        // macOS, so match the change value text: the mock fixes pages row
        // 0 at 493 vs previous 443, a +11% delta.
        XCTAssertTrue(reveal("breakdown-pages-summary-0").waitForExistence(timeout: 15))
        reveal("breakdown-pages-show-all").click()
        XCTAssertTrue(app.sheets.element(boundBy: 0).waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-pages-row-0").waitForExistence(timeout: 15))
        sleep(1)
        element("breakdown-pages-row-0").click()
        XCTAssertTrue(app.windows["/pricing"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("▲ +11%").waitForExistence(timeout: 15))
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 15))
    }

    func testOverviewCardsAndMetricSwitch() throws {
        launch()
        openDetail()
        // Headline cards render the mock top-stats aggregates in order.
        XCTAssertTrue(element("overview-stat-visitors").waitForExistence(timeout: 15))
        XCTAssertTrue(element("overview-stat-bounce_rate").exists)
        // The chart exposes a stable voice label (its id is shadowed).
        XCTAssertTrue(element("Unique visitors chart, 8 buckets").waitForExistence(timeout: 15))
        // Switching the chart metric reloads the series with its own identity.
        menuButton("Unique visitors").click()
        menuItem("Total visits").click()
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
