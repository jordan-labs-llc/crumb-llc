import XCTest

/// Drives the full "buying premium lacrosse gear" journey against the LIVE broker (no
/// CRUMB_SCREENSHOT, so the real UCP catalog + curator are used — the mock has no lacrosse gear).
///
/// This is the regression journey for #64: a live run reached checkout with a cart of pet/novelty
/// products (dog collars, a lacrosse stick sold by `3poochescollars.com`) because those titles share
/// the word "lacrosse" and rode keyword overlap through the relevance gate. The fix adds a pet/novelty
/// negative floor to `RuleBasedRelevanceGate`; this journey captures screenshots at every step and
/// asserts the settled deck and the cart never surface a product that clearly reads as a pet product.
///
/// Like the jasmine journey it is soft by construction: `continueAfterFailure` is on and every step
/// probes with `waitForExistence`, so the run always walks as far as the app allows and records
/// exactly where (and how) it breaks — the pet-product assertions are the one hard contract.
final class LacrosseGearJourneyTests: XCTestCase {

    var app: XCUIApplication!

    /// Substrings that betray a pet/novelty product in a rendered card or cart line — the exact
    /// offenders from the #64 report plus their generalizations.
    private let petMarkers = ["dog", "pooch", "puppy", "kitten", "leash", "bow tie", "bowtie"]

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["CRUMB_UITEST"] = "1"   // no CRUMB_SCREENSHOT -> live broker
    }

    // MARK: - capture helpers

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name).tree.txt"; tree.lifetime = .keepAlways; add(tree)
        NSLog("CRUMB-LACROSSE snap=\(name)")
    }

    /// Fails if the current screen's accessibility tree mentions any pet/novelty marker — the #64
    /// contract. Lowercased substring match over the whole tree dump, so it catches a pet product
    /// whether it shows in a card title, a rationale line, a cart row, or the merchant name.
    private func assertNoPetProducts(_ where_: String) {
        let tree = app.debugDescription.lowercased()
        for marker in petMarkers {
            XCTAssertFalse(tree.contains(marker),
                           "#64 regression: \(where_) surfaced a pet/novelty product (matched \"\(marker)\")")
        }
    }

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
            NSLog("CRUMB-LACROSSE MISSING \(label)"); return false
        }
        let deadline = Date().addingTimeInterval(5)
        while !e.isHittable && Date() < deadline { usleep(200_000) }
        e.tap()
        NSLog("CRUMB-LACROSSE tapped \(label)")
        return true
    }

    // MARK: - the journey

    @MainActor
    func testLacrosseGearPurchaseJourney() {
        app.launch()

        _ = el("onboardingSkip").waitForExistence(timeout: 20)
        snap("00-launch")

        var skip = app.buttons["onboardingSkip"]
        if !skip.exists { skip = app.buttons["Skip"] }
        waitTap(skip, 5, "onboardingSkip")

        let greeting = app.staticTexts["What are we shopping for?"]
        _ = greeting.waitForExistence(timeout: 15)
        snap("01-missions")

        let field = el("composerField")
        if waitTap(field, 10, "composerField") {
            field.typeText("premium lacrosse gear")
            snap("02-goal-typed")
        }
        waitTap(app.buttons["planButton"], 5, "planButton")

        // ---- Plan artifact inside the stable mission thread ----
        if el("MissionThreadScreen").waitForExistence(timeout: 60),
           prefixed("missionArtifact.plan.").waitForExistence(timeout: 12) {
            usleep(600_000)
            snap("03-plan")
            XCTAssertFalse(el("MissionsScreen").exists,
                           "Missions remained exposed behind the mission thread")
            XCTAssertTrue(prefixed("missionArtifact.plan.").label.localizedCaseInsensitiveContains("helmet"),
                          "#68: lacrosse gear plan should contain concrete safety/fit parts")
            waitTap(option("start-shopping"), 12, "Start shopping")
        } else {
            snap("03-plan-timeout"); return
        }

        // ---- Frozen product question in the same conversation ----
        if prefixed("missionArtifact.product.").waitForExistence(timeout: 90) {
            snap("04-product-first")
            XCTAssertTrue(el("MissionThreadScreen").exists,
                          "MissionThreadScreen disappeared during product discovery")
            assertNoPetProducts("first product question")
            for i in 0..<3 {
                let add = option("add")
                if add.waitForExistence(timeout: 20), add.isEnabled {
                    snap("05-product-\(i)")
                    assertNoPetProducts("product question \(i)")
                    add.tap()
                    usleep(700_000)
                } else { break }
            }
            snap("06-after-adds")
        } else {
            snap("04-product-timeout"); return
        }

        // ---- Finish the product questions, then review the kit through the dock. ----
        for _ in 0..<30 {
            if option("review-cart").waitForExistence(timeout: 1) { break }
            guard waitTap(option("skip"), 20, "Skip remaining product") else { break }
        }
        waitTap(option("review-cart"), 15, "Review cart")

        if el("CartScreen").waitForExistence(timeout: 15) {
            snap("07-cart")
            // #64 contract: the checkoutable cart must contain no pet/novelty product.
            assertNoPetProducts("cart")
            // #67 note: the cart's kit-readiness panel (`kitCompletenessWarning` / `kitReady`) only
            // renders for a *complete-kit* mission. Whether "premium lacrosse gear" reaches Cart as a
            // kit or a single-item shortlist depends on the on-device planner's decomposition, which
            // is non-deterministic on the sim — so this live journey doesn't hard-assert the panel.
            // #67's guard is validated deterministically by KitCompletenessCartUITests (a seed kit
            // mission) and the KitCompleteness/AppModel unit tests.
            waitTap(app.buttons["startCheckoutButton"], 10, "startCheckoutButton")
        } else {
            snap("07-cart-timeout"); return
        }

        // ---- Checkout workflow (do NOT tap continue -> external URL) ----
        if el("CheckoutWorkflow").waitForExistence(timeout: 15) {
            snap("08-checkout-workflow")
            // #64 contract: the first handoff must not be for a pet/novelty product.
            assertNoPetProducts("checkout handoff")
        } else {
            snap("08-checkout-missing")
        }
        snap("09-final")
    }
}
