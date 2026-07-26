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

        // Every sandbox-provenance merchant shows its own contact form, so a 3-shop cart has three
        // sandboxFirstName fields — scope the contact phase to the first merchant card (the same
        // merchant the seeded stages fill) instead of ambiguous app-wide queries.
        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'merchantCheckout.'")).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        let values = [
            ("sandboxFirstName", "Sample"), ("sandboxLastName", "Shopper"),
            ("sandboxEmail", "sample@example.invalid"), ("sandboxStreet", "1 Sandbox Way"),
            ("sandboxCity", "Testville"), ("sandboxRegion", "CA"),
            ("sandboxPostalCode", "94107"),
        ]
        for (identifier, value) in values {
            let field = firstCard.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing \(identifier)")
            field.tap(); field.typeText(value)
        }
        firstCard.buttons["sandboxSubmitContact"].tap()
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
        let placeOrder = app.buttons["sandboxPlaceOrder"]
        XCTAssertTrue(placeOrder.waitForExistence(timeout: 10))

        // A SwiftUI Toggle's element frame spans label + switch, so a center tap can land on the
        // label and silently do nothing; tap the embedded switch control (falling back to the
        // trailing edge), then require the acknowledgement to actually enable Place order —
        // a tap on the disabled button is a silent no-op.
        let acknowledgement = app.switches["sandboxReviewAcknowledgement"]
        let control = acknowledgement.switches.firstMatch
        (control.exists ? control : acknowledgement).tap()
        if (acknowledgement.value as? String) != "1" {
            acknowledgement.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertTrue(placeOrder.wait(for: \.isEnabled, toEqual: true, timeout: 5),
                      "Acknowledgement toggle did not enable Place order")
        placeOrder.tap()
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
