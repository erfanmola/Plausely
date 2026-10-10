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








/// Home tab flows against the deterministic 13-site mock directory.
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

    private func openSite(_ domain: String = "alpha-1.example.com") {
        chooseSite(domain, expectPill: domain)
        XCTAssertTrue(element("home-hero-count").waitForExistence(timeout: 20))
    }

    /// Site/account selection with verification: opens the site menu,
    /// picks the row, and proves the pill retargeted. Retries the whole
    /// cycle — under load a tap can land mid-layout-shift and silently
    /// miss, and sites arrive asynchronously after launch. Blind toggles
    /// converge: a tap on an open menu closes it, the next tap reopens.
    private func chooseSite(_ domain: String, expectPill: String? = nil, expectChangeFrom: String? = nil, expectHero: Bool = true) {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            pillTap()
            if peekOption(domain, timeout: 8) != nil {
                selectOption(domain)
                // Settle for the async selection to land (account
                // switches clear the site first, so the hero may lag the
                // pill — or never come when no site stays selected).
                let settled = Date().addingTimeInterval(10)
                var ok = false
                while Date() < settled {
                    let pillLabel = element("home-site").label
                    let pillOk = expectPill.map { pillLabel.contains($0) } ?? true
                    let changedOk = expectChangeFrom.map { pillLabel != $0 } ?? true
                    let heroOk = !expectHero || element("home-hero-count").exists
                    if pillOk, changedOk, heroOk { ok = true; break }
                    sleep(1)
                }
                if ok { return }
                // Tapped but state did not settle: close the menu for a
                // clean retry.
                pillTap()
                sleep(1)
            } else {
                // Menu closed on tap, or opened before rows loaded: beat
                // for the async directory, then retry.
                sleep(2)
            }
        }
        XCTFail("site menu never selected \(domain)")
    }

    /// Header pill tap without scrolling games: callers ensure position
    /// first (scrollToTop). Resolves fresh and taps immediately so no
    /// layout shift can stale the coordinate.
    private func pillTap() {
        scrollToTop()
        let pill = element("home-site")
        XCTAssertTrue(pill.waitForExistence(timeout: 15))
        pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
    }

    /// Returns content to the top so header pills are tappable. Only the
    /// scroll content moves; the floating tab bar is unaffected. Uses
    /// element swipes: press-drags from screen center are captured by the
    /// metric-picker menu/chart gestures and never scroll.
    private func scrollToTop(timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pill = element("home-site")
            if pill.exists, pill.isHittable, pill.frame.minY >= 0 { break }
            app.swipeDown()
            sleep(1)
        }
    }

    private func tab(_ name: String) {
        // Native tab bar buttons carry titles, not our identifiers: match
        // the visible title, tap natively (the bar never moves), then
        // prove the pane switched. Capitalized raw values equal the
        // tabItem titles for all four tabs.
        let title = name.capitalized
        let deadline = Date().addingTimeInterval(30)
        while !element("home-pane-\(name)").exists, Date() < deadline {
            let button = app.tabBars.firstMatch.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            sleep(2)
        }
        XCTAssertTrue(element("home-pane-\(name)").waitForExistence(timeout: 5))
    }

    private func menuOption(_ option: String, timeout: TimeInterval = 15) -> XCUIElement {
        guard let match = peekOption(option, timeout: timeout) else {
            XCTFail("option \(option)")
            return app.descendants(matching: .button)[option].firstMatch
        }
        return match
    }

    /// Drives a pill menu until the pill itself reads the expected option.
    /// Pill relabel (plus menu dismissal) is the only proof a tap
    /// selected; retries missed taps. Already-selected returns at once.
    private func choosePill(pill: String, expecting: String, timeout: TimeInterval = 90) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let p = element(pill)
            if p.exists, p.label.contains(expecting) { return }
            let current = (p.exists && !p.label.isEmpty) ? p.label : expecting
            openMenu(button: current, expecting: expecting, timeout: 20)
            selectOption(expecting)
            sleep(2)
        }
        XCTFail("pill \(pill) never read \(expecting)")
    }

    /// Non-asserting probe: nil when the option never appears (menu still
    /// loading), so retry loops don't log failures per attempt. Matches
    /// buttons only: menu option labels also exist as inert StaticText
    /// snapshots, and tapping those is a silent no-op.
    private func peekOption(_ option: String, timeout: TimeInterval) -> XCUIElement? {
        let match = app.descendants(matching: .button)[option].firstMatch
        guard match.waitForExistence(timeout: timeout) else { return nil }
        // Let the menu animation settle so taps land on the right row.
        sleep(1)
        return match
    }

    private func menuButton(_ title: String, timeout: TimeInterval = 15) -> XCUIElement {
        // Pills live inside the scroll content and can sit off-screen:
        // page toward the labeled button (down when it sits above the
        // band, up when below), then resolve it fresh — scrolling
        // invalidates earlier snapshots. Matches by visible title.
        let deadline = Date().addingTimeInterval(timeout)
        var button = app.descendants(matching: .button)[title].firstMatch
        while Date() < deadline {
            if button.exists {
                let frame = button.frame
                let height = app.frame.height
                if frame.minY > height * 0.05, frame.maxY < height * 0.85 { break }
                // Element swipes, not press-drags: center press-drags are
                // captured by menu/chart gestures and never scroll.
                if frame.minY <= height * 0.05 {
                    app.swipeDown()
                } else {
                    app.swipeUp()
                }
                sleep(1)
                button = app.descendants(matching: .button)[title].firstMatch
            } else {
                // Not laid out yet: nudge upward; content below the fold
                // is the common case.
                app.swipeUp()
                sleep(1)
                button = app.descendants(matching: .button)[title].firstMatch
            }
        }
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "menu \(title)")
        sleep(1)
        // Resolve fresh after the settle beat: async reloads shift layout,
        // and tapping a stale snapshot misses the menu entirely.
        return app.descendants(matching: .button)[title].firstMatch
    }

    /// Opens a Menu button and proves the expected option appeared,
    /// retrying taps that land mid-layout-shift and silently miss. Menu
    /// rows are static, so an open menu always offers its options: if the
    /// option is already visible, no tap is needed. The post-tap probe is
    /// deliberately long — a short one toggles a slowly-presenting menu
    /// back closed and oscillates forever.
    private func openMenu(button: String, expecting: String, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if peekOption(expecting, timeout: 2) != nil { return }
            let b = menuButton(button, timeout: 10)
            b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if peekOption(expecting, timeout: 8) != nil { return }
        }
        XCTFail("menu \(button) never offered \(expecting)")
    }

    /// Picks an open-menu option: waits out the presentation animation
    /// for hittability, then coordinate-taps so no auto-scroll can steal
    /// the landing.
    private func selectOption(_ option: String, timeout: TimeInterval = 15) {
        guard let match = peekOption(option, timeout: timeout) else {
            XCTFail("option \(option)")
            return
        }
        let deadline = Date().addingTimeInterval(5)
        while !match.isHittable, Date() < deadline { sleep(1) }
        XCTAssertTrue(match.isHittable, "option not hittable \(option)")
        match.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func reveal(_ identifier: String, timeout: TimeInterval = 20) -> XCUIElement {
        // Directional paging with element swipes (press-drags from
        // center are captured by menu/chart gestures and never scroll):
        // up when the target sits below the band, down when it scrolled
        // past above it. Band stays clear of the status bar and the
        // floating tab bar. Overshoot self-corrects next iteration.
        let target = element(identifier)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists {
                let frame = target.frame
                let height = app.frame.height
                if frame.height > height * 0.6 { break }
                if frame.minY > height * 0.05, frame.maxY < height * 0.85 { break }
                if frame.minY <= height * 0.05 {
                    app.swipeDown()
                } else {
                    app.swipeUp()
                }
            } else {
                app.swipeUp()
            }
            sleep(1)
        }
        // Let any residual deceleration die before the caller taps:
        // taps that land mid-scroll are eaten as scroll-stops.
        sleep(2)
        return target
    }

    /// Taps a show-all/hub button until its sheet exists. Content loads
    /// asynchronously and shifts rows under the finger, so a single tap
    /// can land on the wrong row — re-resolve and retry instead.
    private func openSheet(_ buttonID: String, sheetID: String = "breakdown-full", timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element(sheetID).exists, Date() < deadline {
            tap(buttonID)
            sleep(2)
        }
        XCTAssertTrue(element(sheetID).waitForExistence(timeout: 5))
    }

    /// Position then coordinate-tap: AX taps auto-scroll first, which moves
    /// content under slow renderers and misses. Re-resolve after the
    /// scroll settles so the coordinate is current, then tap immediately.
    private func tap(_ identifier: String, timeout: TimeInterval = 20) {
        _ = reveal(identifier, timeout: timeout)
        let fresh = element(identifier)
        XCTAssertTrue(fresh.waitForExistence(timeout: 5), "tap target \(identifier)")
        fresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }


    func testSiteSelectionAndSwitch() throws {
        launch()
        openSite()
        // Long domains survive the site menu without dropping the row.
        let longDomain = "extremely-long-subdomain-name-for-truncation-testing-purposes.example.com"
        chooseSite(longDomain, expectPill: longDomain)
        XCTAssertTrue(element("home-hero-count").waitForExistence(timeout: 15))
        // Instance switching re-targets the site menu: any viewer site
        // proves the switch (account switches clear the site, so no
        // hero is expected), and the old account's rows vanish.
        chooseSite("viewer@example.com", expectChangeFrom: longDomain, expectHero: false)
        XCTAssertTrue(element("home-site").waitForExistence(timeout: 15))
        scrollToTop()
        pillTap()
        XCTAssertTrue(menuOption("local.example").waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["alpha-1.example.com"].waitForExistence(timeout: 5))
        pillTap()
    }

    func testQueryToolbarPeriodsAndComparison() throws {
        launch()
        openSite()
        // Period presets rewrite the query; the pill label tracks state.
        choosePill(pill: "home-period", expecting: "Last 7 days")
        XCTAssertTrue(element("Last 7 days").waitForExistence(timeout: 15))
        choosePill(pill: "home-period", expecting: "Yesterday")
        XCTAssertTrue(element("Yesterday").waitForExistence(timeout: 15))
        // Comparisons apply with the weekday-alignment toggle…
        XCTAssertTrue(reveal("comparison-picker").waitForExistence(timeout: 15))
        choosePill(pill: "comparison-picker", expecting: "Previous period")
        XCTAssertTrue(element("Previous period").waitForExistence(timeout: 15))
        XCTAssertTrue(element("Match day of week").waitForExistence(timeout: 15))
        // …and realtime refuses comparisons with a typed message.
        choosePill(pill: "comparison-picker", expecting: "No comparison")
        choosePill(pill: "home-period", expecting: "Realtime")
        // Refused selections keep their pill, so the message itself is
        // the outcome: re-drive until it answers.
        let rdeadline = Date().addingTimeInterval(90)
        while !element("Comparisons are off for realtime.").exists, Date() < rdeadline {
            let current = element("comparison-picker").label
            openMenu(button: current.isEmpty ? "No comparison" : current, expecting: "Previous period")
            selectOption("Previous period")
            sleep(2)
        }
        XCTAssertTrue(element("Comparisons are off for realtime.").waitForExistence(timeout: 5))
    }

    func testFilterAddSuggestAndRemove() throws {
        launch()
        openSite()
        // The clause sheet is the only proof the Add tap landed: retry
        // until it answers.
        let fadeadline = Date().addingTimeInterval(60)
        while !element("clause-value").exists, Date() < fadeadline {
            tap("filter-add")
            sleep(2)
        }
        let valueField = element("clause-value")
        XCTAssertTrue(valueField.waitForExistence(timeout: 5))
        valueField.tap()
        valueField.typeText("Goo")
        tap("suggestion-Google")
        XCTAssertTrue(element("clause-value-Google").waitForExistence(timeout: 15))
        tap("clause-add")
        XCTAssertTrue(element("Source is Google").waitForExistence(timeout: 15))
        tap("filter-remove-0")
        XCTAssertFalse(element("Source is Google").waitForExistence(timeout: 5))
    }

    func testSegmentApplyAndRemove() throws {
        launch()
        openSite()
        // A tap can land on a neighboring row when content shifts under
        // load; the applied chip is the only proof. Single-segment
        // semantics replace any mis-tap, so retrying converges.
        let sdeadline = Date().addingTimeInterval(60)
        while !element("segment-applied-7").exists, Date() < sdeadline {
            tap("segment-apply-7")
            sleep(2)
        }
        XCTAssertTrue(element("segment-applied-7").waitForExistence(timeout: 15))
        XCTAssertTrue(element("Operating system is iOS").waitForExistence(timeout: 15))
        tap("segment-clear")
        XCTAssertFalse(element("Operating system is iOS").waitForExistence(timeout: 5))
    }

    func testBreakdownSummaryToDetail() throws {
        launch()
        openSite()
        tab("breakdowns")
        XCTAssertTrue(reveal("breakdown-sources-summary-0").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-summary-4").exists)
        openSheet("breakdown-sources-show-all")
        tap("sort-option-breakdown-sources-name-desc")
        do {
            let first = element("breakdown-sources-row-0")
            let deadline = Date().addingTimeInterval(15)
            while !first.label.contains("Source 1500"), Date() < deadline { sleep(1) }
            XCTAssertTrue(first.label.contains("Source 1500"))
        }
        tap("breakdown-sources-row-0")
        XCTAssertTrue(element("breakdown-referrers-drilldown-row-0").waitForExistence(timeout: 15))
        tap("breakdown-referrers-drilldown-row-0")
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
        tap("breakdown-referrers-drilldown-filter")
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        do {
            let row = element("breakdown-sources-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testChannelsDrillToFilteredSources() throws {
        launch()
        openSite()
        tab("breakdowns")
        XCTAssertTrue(reveal("breakdown-channels-summary-0").waitForExistence(timeout: 15))
        openSheet("breakdown-channels-show-all")
        XCTAssertTrue(element("breakdown-channels-row-0").waitForExistence(timeout: 15))
        let channel = element("breakdown-channels-row-0").label
        tap("breakdown-channels-row-0")
        XCTAssertTrue(app.navigationBars["Sources · \(channel)"].waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-empty").waitForExistence(timeout: 15))
        tap("breakdown-sources-close")
        XCTAssertTrue(element("breakdown-channels-row-0").waitForExistence(timeout: 15))
        tap("breakdown-channels-close")
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
    }

    func testUtmHubToFilter() throws {
        launch()
        openSite()
        tab("breakdowns")
        XCTAssertTrue(reveal("breakdown-utm-hub").waitForExistence(timeout: 15))
        openSheet("breakdown-utm-hub", sheetID: "breakdown-hub")
        XCTAssertTrue(element("breakdown-hub-utm_mediums").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-hub-utm_contents").exists)
        tap("breakdown-hub-utm_mediums")
        XCTAssertTrue(element("breakdown-utm_mediums-row-0").waitForExistence(timeout: 15))
        tap("breakdown-utm_mediums-row-0")
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
        tap("breakdown-utm_mediums-filter")
        XCTAssertFalse(element("breakdown-hub").waitForExistence(timeout: 5))
        do {
            let row = element("breakdown-sources-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testPagesFilterAndOpen() throws {
        launch()
        openSite()
        tab("breakdowns")
        XCTAssertTrue(reveal("breakdown-pages-summary-0").waitForExistence(timeout: 15))
        openSheet("breakdown-pages-show-all")
        XCTAssertTrue(element("breakdown-pages-row-0").waitForExistence(timeout: 15))
        tap("breakdown-pages-row-0")
        XCTAssertTrue(element("breakdown-pages-detail-name").waitForExistence(timeout: 15))
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
        tap("breakdown-pages-filter")
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        do {
            let row = element("breakdown-sources-summary-0")
            let deadline = Date().addingTimeInterval(15)
            while row.exists, Date() < deadline { sleep(1) }
            XCTAssertFalse(row.exists)
        }
    }

    func testEntryAndExitFilterFlows() throws {
        launch()
        openSite()
        tab("breakdowns")
        XCTAssertTrue(reveal("breakdown-entry-pages-summary-0").waitForExistence(timeout: 15))
        openSheet("breakdown-entry-pages-show-all")
        XCTAssertTrue(element("breakdown-entry-pages-row-0").waitForExistence(timeout: 15))
        tap("breakdown-entry-pages-row-0")
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
        tap("breakdown-entry-pages-filter")
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal("breakdown-exit-pages-summary-0").waitForExistence(timeout: 15))
        openSheet("breakdown-exit-pages-show-all")
        XCTAssertTrue(element("breakdown-exit-pages-row-0").waitForExistence(timeout: 15))
        tap("breakdown-exit-pages-row-0")
        XCTAssertTrue(element("breakdown-exit-pages-detail-name").waitForExistence(timeout: 15))
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
        tap("breakdown-exit-pages-filter")
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
    }

    func testComparisonBadgesAcrossWorkflows() throws {
        launch()
        openSite()
        XCTAssertTrue(reveal("comparison-picker").waitForExistence(timeout: 15))
        choosePill(pill: "comparison-picker", expecting: "Previous period")
        XCTAssertTrue(element("Previous period").waitForExistence(timeout: 15))
        tab("breakdowns")
        XCTAssertTrue(reveal("breakdown-sources-summary-change-0-visitors").waitForExistence(timeout: 15))
        do {
            let deadline = Date().addingTimeInterval(30)
            while !element("breakdown-full").exists, Date() < deadline {
                tap("breakdown-sources-show-all")
                sleep(1)
            }
        }
        XCTAssertTrue(element("breakdown-full").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-sources-row-0").waitForExistence(timeout: 15))
        tap("breakdown-sources-close")
        XCTAssertFalse(element("breakdown-full").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal("breakdown-pages-summary-0").waitForExistence(timeout: 15))
        tap("breakdown-pages-show-all")
        XCTAssertTrue(element("breakdown-pages-row-0").waitForExistence(timeout: 15))
        tap("breakdown-pages-row-0")
        XCTAssertTrue(element("breakdown-pages-detail-visitors-change").waitForExistence(timeout: 15))
        XCTAssertTrue(element("breakdown-pages-detail-visitors-comparison").exists)
    }

    func testOverviewCardsAndMetricSwitch() throws {
        launch()
        openSite()
        XCTAssertTrue(reveal("overview-value-visitors").waitForExistence(timeout: 15))
        for metric in ["visitors", "visits", "pageviews", "views_per_visit", "bounce_rate", "visit_duration"] {
            XCTAssertTrue(element("overview-value-\(metric)").exists, "missing card \(metric)")
        }
        XCTAssertTrue(element("Unique visitors chart, 8 buckets").waitForExistence(timeout: 15))
        // The reselected chart is the only proof the option tap landed:
        // re-drive the menu until it answers.
        let mdeadline = Date().addingTimeInterval(90)
        while !element("Total visits chart, 8 buckets").exists, Date() < mdeadline {
            let current = element("metric-picker").label
            openMenu(button: current.isEmpty ? "Unique visitors" : current, expecting: "Total visits")
            selectOption("Total visits")
            sleep(2)
        }
        XCTAssertTrue(element("Total visits chart, 8 buckets").waitForExistence(timeout: 15))
    }

    func testGoalsAndSettingsTabs() throws {
        launch()
        openSite()
        tab("goals")
        XCTAssertTrue(reveal("breakdown-conversions-summary-0").waitForExistence(timeout: 20))
        tab("settings")
        XCTAssertTrue(element("settings-content").waitForExistence(timeout: 15))
        XCTAssertTrue(element("settings-account-owner@example.com").waitForExistence(timeout: 15))
    }

    func testSitePickerPinAndSelect() throws {
        launch()
        // Unselected state is the full picker, not an empty card.
        XCTAssertTrue(element("site-picker-title").waitForExistence(timeout: 15))
        XCTAssertTrue(element("site-option-alpha-1.example.com").exists)
        // Pinning surfaces a Pinned section first…
        tap("site-pin-alpha-1.example.com")
        XCTAssertTrue(element("site-picker-pinned").waitForExistence(timeout: 15))
        // …and unpinning removes it again, leaving no persisted state.
        tap("site-pin-alpha-1.example.com")
        XCTAssertFalse(element("site-picker-pinned").waitForExistence(timeout: 5))
        // Picker rows select directly into the overview.
        tap("site-option-beta-1.example.org")
        XCTAssertTrue(element("home-hero-count").waitForExistence(timeout: 20))
    }

    func testDeselectReturnsToPicker() throws {
        launch()
        openSite()
        XCTAssertTrue(element("home-hero-count").waitForExistence(timeout: 20))
        // The menu's escape hatch drops the selection and lands back
        // on the full picker, where pin toggles live.
        pillTap()
        selectOption("All Sites")
        XCTAssertTrue(element("site-picker-title").waitForExistence(timeout: 15))
    }
}
