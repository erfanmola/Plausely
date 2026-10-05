import XCTest

/// Bootstrap smoke test: the app launches into its deterministic mock root.
final class SmokeTests: XCTestCase {
    func testMockLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-plausely-mock")
        app.launch()
        XCTAssertTrue(app.staticTexts["Mock"].waitForExistence(timeout: 15))
    }
}
