import XCTest

/// Deterministic end-to-end coverage for the Cart kit-completeness guard (#67), using the seeded
/// screenshot hook (no live broker, no on-device planner): launch straight into the Cart for the
/// "pour-over corner" seed kit, whose seeded partial cart (kettle + grinder + beans across three
/// shops) covers only three of its five plan parts — so the readiness warning must appear and name
/// the concrete missing categories, and must never frame the partial kit as finished.
final class KitCompletenessCartUITests: XCTestCase {

    @MainActor
    func testNativeSandboxCheckoutLifecycle() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "sandbox-contact"
        app.launchEnvironment["CRUMB_MISSION"] = "coffee"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sandboxBadge")
            .firstMatch.waitForExistence(timeout: 20))
        let values = [
            ("sandboxFirstName", "Sample"), ("sandboxLastName", "Shopper"),
            ("sandboxEmail", "sample@example.invalid"), ("sandboxStreet", "1 Sandbox Way"),
            ("sandboxCity", "Testville"), ("sandboxRegion", "CA"),
            ("sandboxPostalCode", "94107"),
        ]
        for (identifier, value) in values {
            let field = app.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing \(identifier)")
            field.tap(); field.typeText(value)
        }
        app.buttons["sandboxSubmitContact"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sandboxReview")
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sandboxMerchantOfRecord")
            .firstMatch.exists)

        let shipping = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sandboxShipping.'")).firstMatch
        XCTAssertTrue(shipping.waitForExistence(timeout: 5))
        shipping.tap()
        app.buttons["Standard shipping"].tap()
        app.buttons["sandboxUpdateShipping"].tap()
        XCTAssertTrue(app.buttons["sandboxPlaceOrder"].waitForExistence(timeout: 10))
        app.switches["sandboxReviewAcknowledgement"].tap()
        app.buttons["sandboxPlaceOrder"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sandboxConfirmation")
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sandboxOrderID")
            .firstMatch.label.contains("SANDBOX"))
    }

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

        // The same deterministic three-shop cart exercises the UCP workflow disclosure and proves
        // the cart now has one aggregate start action rather than misleading per-shop checkout CTAs.
        let start = app.buttons["startCheckoutButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Cart has no aggregate checkout action")
        start.tap()
        let disclosure = app.descendants(matching: .any)
            .matching(identifier: "multiMerchantDisclosure").firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10),
                      "Multi-store checkout did not disclose that merchants create separate orders")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "merchantAuthoritativeNote").firstMatch.exists,
                      "Checkout workflow omitted merchant-authoritative total disclosure")
    }
}
