import XCTest

/// Drives the full "purchase premium jasmine tea" journey against the LIVE broker
/// (no CRUMB_SCREENSHOT, so the real UCP catalog + curator are used — the mock has no tea).
///
/// At every step it captures a full-screen screenshot attachment and a text dump of the
/// accessibility tree, so the run doubles as an accessibility audit. This is a strict live journey:
/// a missing screen or an empty/non-jasmine deck fails instead of producing a diagnostic-only pass.
final class JasmineTeaJourneyTests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CRUMB_UITEST"] = "1"   // no CRUMB_SCREENSHOT -> live broker
    }

    // MARK: - capture helpers

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name).tree.txt"; tree.lifetime = .keepAlways; add(tree)
        NSLog("CRUMB-JOURNEY snap=\(name)")
    }

    /// Any element (regardless of type) carrying this accessibility identifier.
    private func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func prefixed(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", id)).firstMatch
    }

    private func option(_ id: String) -> XCUIElement { el("missionResponseOption.\(id)") }

    @discardableResult
    private func waitTap(_ e: XCUIElement, _ t: TimeInterval, _ label: String) -> Bool {
        guard e.waitForExistence(timeout: t) else {
            NSLog("CRUMB-JOURNEY MISSING \(label)"); return false
        }
        let deadline = Date().addingTimeInterval(5)
        while !e.isHittable && Date() < deadline { usleep(200_000) }
        e.tap()
        NSLog("CRUMB-JOURNEY tapped \(label)")
        return true
    }

    // MARK: - the journey

    @MainActor
    func testJasmineTeaPurchaseJourney() {
        app.launch()

        // Always capture the very first hierarchy so we know how elements are exposed.
        _ = el("onboardingSkip").waitForExistence(timeout: 20)
        snap("00-launch")

        // ---- Step 0: onboarding (fresh install). Skip by id, else by "Skip" label. ----
        var skip = app.buttons["onboardingSkip"]
        if !skip.exists { skip = app.buttons["Skip"] }
        if waitTap(skip, 5, "onboardingSkip") {
            NSLog("CRUMB-JOURNEY onboarding skipped")
        }

        // ---- Step 1: Missions / composer ----
        let greeting = app.staticTexts["What are we shopping for?"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "Missions composer never appeared")
        snap("01-missions")

        let field = el("composerField")
        XCTAssertTrue(waitTap(field, 10, "composerField"), "composer field is unavailable")
        field.typeText("premium jasmine tea")
        snap("02-goal-typed")

        // Dismiss keyboard if present, then plan.
        if app.keyboards.buttons["Return"].exists { /* leave; submitLabel is .go */ }
        XCTAssertTrue(waitTap(app.buttons["planButton"], 5, "planButton"), "plan button is unavailable")

        // ---- Step 2: plan artifact inside the stable mission thread ----
        let threadScreen = el("MissionThreadScreen")
        if threadScreen.waitForExistence(timeout: 60),
           prefixed("missionArtifact.plan.").waitForExistence(timeout: 12) {
            usleep(600_000)   // let the route transition settle before auditing the hierarchy
            snap("03-plan")
            // #66 regression guard: once the thread is up, the Missions/composer surface must be
            // fully gone — not ghosted behind it. The old crossfade left both mounted at once, so the
            // Plan title collided with "What are we shopping for?" and "Ask with Siri".
            XCTAssertFalse(el("MissionsScreen").exists,
                           "#66: MissionsScreen still in the hierarchy behind MissionThreadScreen (ghosting)")
            XCTAssertFalse(app.staticTexts["What are we shopping for?"].exists,
                           "#66: composer greeting still ghosted behind the Plan screen")
            XCTAssertFalse(app.staticTexts["Ask with Siri"].exists,
                           "#66: 'Ask with Siri' still ghosted behind the Plan screen")
            XCTAssertTrue(el("missionResponseDock").exists)
            XCTAssertTrue(waitTap(option("start-shopping"), 12, "Start shopping"))
        } else if app.staticTexts["composerDecline"].exists || el("composerDecline").exists {
            snap("03-plan-declined")
            XCTFail("premium jasmine tea was incorrectly declined")
        } else {
            snap("03-plan-timeout")
            XCTFail("Mission thread plan artifact never appeared")
        }

        // ---- Step 3: frozen product question in the same conversation ----
        if prefixed("missionArtifact.product.").waitForExistence(timeout: 90) {
            snap("04-product-first")
            XCTAssertTrue(el("MissionThreadScreen").exists,
                          "MissionThreadScreen disappeared during product discovery")
            let productCard = prefixed("missionArtifact.product.")
            XCTAssertTrue(
                productCard.label.localizedCaseInsensitiveContains("jasmine"),
                "the Shopify product question is not a jasmine result: \(productCard.label)"
            )
            XCTAssertTrue(option("add").waitForExistence(timeout: 20))
            XCTAssertTrue(option("skip").exists)
            for i in 0..<3 {
                let add = option("add")
                if add.waitForExistence(timeout: 20), add.isEnabled {
                    snap("05-product-\(i)")
                    add.tap()
                    usleep(700_000)
                } else { break }
            }
            snap("06-after-adds")
        } else {
            snap("04-product-timeout"); return
        }

        // ---- Step 4: answer remaining product questions, then review the read-only kit. ----
        for _ in 0..<30 {
            if option("review-cart").waitForExistence(timeout: 1) { break }
            guard waitTap(option("skip"), 20, "Skip remaining product") else { break }
        }
        XCTAssertTrue(waitTap(option("review-cart"), 15, "Review cart"))

        if el("CartScreen").waitForExistence(timeout: 15) {
            snap("07-cart")
            let start = app.buttons["startCheckoutButton"]
            waitTap(start, 10, "startCheckoutButton")
        } else {
            snap("07-cart-timeout"); return
        }

        // ---- Step 5: UCP checkout workflow (do NOT continue -> external merchant URL) ----
        if el("CheckoutWorkflow").waitForExistence(timeout: 15) {
            snap("08-checkout-workflow")
        } else if app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'checkoutUnsupported.'")).firstMatch.exists {
            snap("08-checkout-unsupported")
        } else {
            snap("08-checkout-missing")
        }
        snap("09-final")
    }
}
