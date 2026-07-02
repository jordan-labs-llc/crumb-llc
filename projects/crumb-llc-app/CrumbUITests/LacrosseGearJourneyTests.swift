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

        // ---- Plan editor ----
        if el("PlanScreen").waitForExistence(timeout: 60) {
            snap("03-plan")
            let curate = el("curateButton")
            let curateByID = curate.waitForExistence(timeout: 12)
            waitTap(curateByID ? curate : app.buttons["Curate my kit"], 12, "curateButton")
        } else {
            snap("03-plan-timeout"); return
        }

        // ---- Curate swipe deck (live catalog search + curation) ----
        if el("CurateScreen").waitForExistence(timeout: 90) {
            snap("04-curate-first")
            // Wait for the deck to settle (the gathering shimmer clears) so we assert on the ranked,
            // gated order — not the transient raw stream. On-device settle can take 50s+.
            let gathering = el("gatheringBanner")
            let settleDeadline = Date().addingTimeInterval(90)
            while gathering.exists && Date() < settleDeadline { usleep(300_000) }
            snap("04-curate-settled")
            // #64 contract: the settled top card must not be a pet/novelty product.
            assertNoPetProducts("settled deck top card")
            for i in 0..<3 {
                var add = app.buttons["addButton"]
                if !add.exists { add = app.buttons["Add to kit"] }
                if add.waitForExistence(timeout: 20), add.isEnabled {
                    snap("05-curate-card-\(i)")
                    assertNoPetProducts("curate card \(i)")
                    add.tap()
                    usleep(700_000)
                } else { break }
            }
            snap("06-curate-after-adds")
        } else {
            snap("04-curate-timeout"); return
        }

        // ---- Kit tray -> Cart ----
        let kitTray = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kit,'")).firstMatch
        waitTap(kitTray, 10, "kitTray")

        if el("CartScreen").waitForExistence(timeout: 15) {
            snap("07-cart")
            // #64 contract: the checkoutable cart must contain no pet/novelty product.
            assertNoPetProducts("cart")
            var cont = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue.'")).firstMatch
            if !cont.exists {
                cont = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue to'")).firstMatch
            }
            waitTap(cont, 10, "continueButton")
        } else {
            snap("07-cart-timeout"); return
        }

        // ---- Checkout handoff sheet (do NOT tap continue -> external URL) ----
        if app.buttons["handoffContinue"].waitForExistence(timeout: 15) {
            snap("08-handoff")
            // #64 contract: the first handoff must not be for a pet/novelty product.
            assertNoPetProducts("checkout handoff")
        } else {
            snap("08-handoff-missing")
        }
        snap("09-final")
    }
}
