import XCTest

/// One UI smoke test: a clean install launches into onboarding and exposes its primary actions.
final class CrumbUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCleanInstallLaunchesToOnboarding() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "onboarding"
        app.launch()

        XCTAssertTrue(app.buttons["onboardingSkip"].waitForExistence(timeout: 20),
                      "A clean install did not reach onboarding.")
        XCTAssertTrue(app.buttons["onboardingNext"].exists,
                      "Onboarding launched without its primary next action.")
    }
}
