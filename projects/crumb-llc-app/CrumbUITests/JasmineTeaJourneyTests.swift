import XCTest

/// Drives the full "purchase premium jasmine tea" journey against the LIVE broker
/// (no CRUMB_SCREENSHOT, so the real UCP catalog + curator are used — the mock has no tea).
///
/// At every step it captures a full-screen screenshot attachment and a text dump of the
/// accessibility tree, so the run doubles as an accessibility audit. Nothing hard-fails:
/// continueAfterFailure is on and each step probes with waitForExistence, so we always walk
/// as far as the app allows and record exactly where (and how) it breaks.
final class JasmineTeaJourneyTests: XCTestCase {

    var app: XCUIApplication!

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
        NSLog("CRUMB-JOURNEY snap=\(name)")
    }

    /// Any element (regardless of type) carrying this accessibility identifier.
    private func el(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

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
        _ = greeting.waitForExistence(timeout: 15)
        snap("01-missions")

        let field = el("composerField")
        if waitTap(field, 10, "composerField") {
            field.typeText("premium jasmine tea")
            snap("02-goal-typed")
        }

        // Dismiss keyboard if present, then plan.
        if app.keyboards.buttons["Return"].exists { /* leave; submitLabel is .go */ }
        waitTap(app.buttons["planButton"], 5, "planButton")

        // ---- Step 2: Plan editor (live planner: network + on-device model / fallback) ----
        let planScreen = el("PlanScreen")
        if planScreen.waitForExistence(timeout: 60) {
            snap("03-plan")
            // #24 regression guard: the plan CTA now carries its OWN id — the screen container no
            // longer clobbers the safeAreaInset button to "PlanScreen". Assert it's queryable by id
            // (fails if the a11y-id clobbering regresses), then tap it. Label fallback kept so the
            // run still completes and captures where it broke.
            let curate = el("curateButton")
            let curateByID = curate.waitForExistence(timeout: 12)
            XCTAssertTrue(curateByID, "curateButton is not queryable by id — #24 a11y-id clobbering regressed")
            waitTap(curateByID ? curate : app.buttons["Curate my kit"], 12, "curateButton")
        } else if app.staticTexts["composerDecline"].exists || el("composerDecline").exists {
            snap("03-plan-declined"); return
        } else {
            snap("03-plan-timeout"); return
        }

        // ---- Step 3: Curate swipe deck (live catalog search + curation) ----
        if el("CurateScreen").waitForExistence(timeout: 90) {
            snap("04-curate-first")
            // #57: once CurateScreen is the accessibility root, the Plan loading surface must be
            // gone — the two states should never be exposed at once.
            XCTAssertFalse(app.staticTexts["Scanning shops for the right pieces…"].exists,
                           "#57: Plan's loading scan row is still exposed after CurateScreen appeared")
            // The deck streams raw picks first, then *settles* into the ranked, curator-voiced order.
            // The blocking "Curating your picks…" spinner (`gatheringBanner`) must NOT linger over an
            // actionable deck: within the settle window it either clears (settled) or downgrades to
            // the quiet, non-blocking `refiningBanner` (#57). Wait out that window, then assert.
            let deckReady = app.buttons["addButton"].waitForExistence(timeout: 30)
            XCTAssertTrue(deckReady, "deck never became actionable")
            // Poll until the blocking spinner is gone (bounded well above the 12s downgrade window).
            let gathering = el("gatheringBanner")
            let bannerDeadline = Date().addingTimeInterval(30)
            while gathering.exists && Date() < bannerDeadline { usleep(300_000) }
            snap("04-curate-settled")
            // #57 core contract: no long-lived blocking spinner over a usable deck.
            XCTAssertFalse(app.buttons["addButton"].exists && el("gatheringBanner").exists,
                           "#57: `gatheringBanner` spinner still shown while the deck is actionable")
            // #24 regression guard: the deck controls must carry their OWN ids, not the screen
            // container's — before the fix addButton/skipButton both reported "CurateScreen".
            XCTAssertTrue(app.buttons["addButton"].waitForExistence(timeout: 20),
                          "addButton is not queryable by id — #24 a11y-id clobbering regressed")
            XCTAssertTrue(app.buttons["skipButton"].exists,
                          "skipButton is not queryable by id — #24 a11y-id clobbering regressed")
            for i in 0..<3 {
                var add = app.buttons["addButton"]
                if !add.exists { add = app.buttons["Add to kit"] }
                if add.waitForExistence(timeout: 20), add.isEnabled {
                    snap("05-curate-card-\(i)")
                    add.tap()
                    usleep(700_000)
                } else { break }
            }
            snap("06-curate-after-adds")
        } else {
            snap("04-curate-timeout"); return
        }

        // ---- Step 4: open the Kit tray -> Cart. Tray label begins "Kit,". ----
        let kitTray = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Kit,'")).firstMatch
        waitTap(kitTray, 10, "kitTray")

        if el("CartScreen").waitForExistence(timeout: 15) {
            snap("07-cart")
            var cont = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue.'")).firstMatch
            if !cont.exists {
                cont = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue to'")).firstMatch
            }
            waitTap(cont, 10, "continueButton")
        } else {
            snap("07-cart-timeout"); return
        }

        // ---- Step 5: Checkout handoff sheet (do NOT tap continue -> external URL) ----
        if app.buttons["handoffContinue"].waitForExistence(timeout: 15) {
            snap("08-handoff")
        } else if el("handoffUnavailable").exists {
            snap("08-handoff-unavailable")
        } else {
            snap("08-handoff-missing")
        }
        snap("09-final")
    }
}
