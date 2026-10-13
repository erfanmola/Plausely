import XCTest

/// README screenshots against deterministic mock data. The test runner's
/// environment is sanitized by xcodebuild, so captures always land in
/// /tmp; scripts/screenshots.sh runs this test and moves them into
/// assets/. Run via that script, not bare xcodebuild.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    private func dir() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
    }

    private func shoot(_ name: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir().appendingPathComponent(name))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testReadmeScreenshots() throws {
        app = XCUIApplication()
        app.launchArguments.append("-plausely-mock-sites")
        app.launch()
        XCTAssertTrue(element("site-picker-title").waitForExistence(timeout: 20))
        element("site-option-alpha-1.example.com").tap()
        XCTAssertTrue(element("home-hero-count").waitForExistence(timeout: 20))
        sleep(2)
        try shoot("screenshot-ios-overview.png")
        app.tabBars.firstMatch.buttons["Breakdowns"].firstMatch.tap()
        XCTAssertTrue(element("breakdown-sources-summary-0").waitForExistence(timeout: 20))
        sleep(2)
        try shoot("screenshot-ios-breakdowns.png")
    }
}
