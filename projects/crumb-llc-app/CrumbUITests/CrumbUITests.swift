import XCTest

/// One UI smoke test: the app launches and lands on the Missions screen.
final class CrumbUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesToMissions() {
        let app = XCUIApplication()
        app.launch()

        // The Missions greeting is the landing copy on first screen.
        let greeting = app.staticTexts["What are we shopping for?"]
        XCTAssertTrue(
            greeting.waitForExistence(timeout: 15),
            "Expected the app to launch onto the Missions screen."
        )
    }
}
