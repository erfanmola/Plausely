import XCTest

/// macOS README screenshot against deterministic mock data. Mirrors the iOS
/// ScreenshotTests: launches with `-plausely-mock-sites`, selects
/// alpha-1, waits for the detail, then attaches the main-window capture.
/// The mac test runner is sandboxed (no /tmp writes), so the shot travels
/// as an `XCTAttachment` and scripts/screenshots.sh exports it from the
/// .xcresult with `xcresulttool export attachments`.
/// Run via scripts/screenshots.sh with PLAUSLEY_MAC_UI=1 (the suite drives
/// the real screen, like the rest of the macOS UI tests).
@MainActor
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testReadmeScreenshot() throws {
        app = XCUIApplication()
        app.launchArguments.append("-plausely-mock-sites")
        app.launch()
        XCTAssertTrue(element("site-sidebar").waitForExistence(timeout: 20))
        // Rows arrive asynchronously after launch; a single click can land
        // mid-layout and silently miss, so re-drive until the detail lands.
        let deadline = Date().addingTimeInterval(60)
        while !element("site-detail").exists, Date() < deadline {
            let row = element("site-row-alpha-1.example.com")
            if row.waitForExistence(timeout: 5) {
                row.click()
                sleep(2)
            }
        }
        XCTAssertTrue(element("site-detail").waitForExistence(timeout: 5))
        // macOS virtualizes off-fold rows out of the AX tree: page the
        // detail scrollbar until the stat materializes, like the shell
        // tests' reveal helper.
        XCTAssertTrue(reveal("overview-value-visitors").waitForExistence(timeout: 15))
        sleep(2)
        // Window-only capture: the screen shot would include the user's
        // desktop wallpaper.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "screenshot-macos-overview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Pages the detail scrollbar until the target is on-screen and in the
    /// AX tree. macOS virtualizes off-fold rows away; bare existence waits
    /// never see them. Mirrors SiteShellTests.reveal.
    private func reveal(_ identifier: String, timeout: TimeInterval = 20) -> XCUIElement {
        let target = element(identifier)
        let deadline = Date().addingTimeInterval(timeout)
        var pages = 0
        while (!target.exists || !target.isHittable), Date() < deadline, pages < 8 {
            let bars = element("site-detail").scrollBars
            guard bars.count > 0 else { break }
            bars.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)).click()
            pages += 1
        }
        while !target.isHittable, Date() < deadline { sleep(1) }
        return target
    }
}
