import XCTest

/// Deterministic end-to-end coverage for the Cart kit-completeness guard (#67), using the seeded
/// screenshot hook (no live broker, no on-device planner): launch straight into the Cart for the
/// "pour-over corner" seed kit, whose seeded partial cart (kettle + grinder + beans across three
/// shops) covers only three of its five plan parts — so the readiness warning must appear and name
/// the concrete missing categories, and must never frame the partial kit as finished.
final class KitCompletenessCartUITests: XCTestCase {

    @MainActor
    func testIncompleteKitCartShowsMissingCategoryWarning() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "cart"   // deep-link straight to the Cart…
        app.launchEnvironment["CRUMB_MISSION"] = "coffee"    // …for the pour-over kit (5-part plan)
        app.launch()

        XCTAssertTrue(app.otherElements["CartScreen"].waitForExistence(timeout: 20)
                      || app.scrollViews["CartScreen"].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any).matching(identifier: "CartScreen").firstMatch.waitForExistence(timeout: 5),
                      "Cart never appeared")

        let warning = app.descendants(matching: .any).matching(identifier: "kitCompletenessWarning").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10),
                      "#67: incomplete kit cart shows no missing-category warning")

        // The warning must name concrete missing categories (Dripper + the mat), not a generic error.
        let missing = app.descendants(matching: .any).matching(identifier: "kitMissingList").firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 5), "#67: no missing-category list")
        let text = missing.label
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Dripper"),
                      "#67: missing list should name the uncovered categories; got: \(text)")

        // And it must not simultaneously claim the kit is complete.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "kitReady").firstMatch.exists,
                       "#67: incomplete kit must not show the 'covers the plan' ready state")
    }
}
