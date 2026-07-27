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
        // Launch into an empty app. Nothing resets the simulator between tests, all three tests
        // here shop the same goal, and they run alphabetically — so the purchase journey's mission
        // is still in the thread store when the mid-gather test sends the same goal. The app then
        // resumes that settled mission rather than gathering, and the test waits out its full 120s
        // for a "Searching the shops…" dock that never comes. It survives across *runs* too, which
        // is why the failure repeats once it starts. Store isolation only — seams stay live.
        app.launchEnvironment["CRUMB_UITEST_RESET_STORE"] = "1"
        // Hold every gather open for 8s. `testMidGatherRefinementBuffersAndApplies` has to type
        // while the search is still running, and a warm simulator can finish one faster than a UI
        // test can see it — which is the whole reason that test used to fail intermittently. The
        // broker, the curator and the buffering are untouched; only the window is made knowable.
        app.launchEnvironment["CRUMB_UITEST_GATHER_HOLD_MS"] = "8000"
        // Pin Dynamic Type instead of inheriting whatever the device is set to. This journey reads
        // the conversation itself — inline dock options and the status lines in the feed — and at an
        // accessibility size the dock folds its options behind `missionResponseChoiceDisclosure`
        // while the feed keeps barely one turn realized, so the same app state stops being
        // queryable. The accessibility layout has its own coverage:
        // `MissionThreadUITests.testProductQuestionAtAccessibilityXXXL`.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
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

        XCTAssertTrue(el("missionResponseDock").waitForExistence(timeout: 10))
        let field = el("missionResponseField")
        XCTAssertTrue(waitTap(field, 10, "missionResponseField"), "composer field is unavailable")
        field.typeText("premium jasmine tea")
        snap("02-goal-typed")

        XCTAssertTrue(waitTap(el("missionResponseSend"), 5, "missionResponseSend"), "send is unavailable")

        // ---- Step 2: the thread mounts and shops immediately (direct missions: no plan turn) ----
        let threadScreen = el("MissionThreadScreen")
        if threadScreen.waitForExistence(timeout: 60) {
            usleep(600_000)   // let the route transition settle before auditing the hierarchy
            snap("03-thread")
            // #66 regression guard: once the thread is up, the Missions/composer surface must be
            // fully gone — not ghosted behind it. The old crossfade left both mounted at once, so the
            // thread title collided with "What are we shopping for?" and "Ask with Siri".
            XCTAssertFalse(el("MissionsScreen").exists,
                           "#66: MissionsScreen still in the hierarchy behind MissionThreadScreen (ghosting)")
            XCTAssertFalse(app.staticTexts["What are we shopping for?"].exists,
                           "#66: composer greeting still ghosted behind the mission thread")
            XCTAssertFalse(app.staticTexts["Ask with Siri"].exists,
                           "#66: 'Ask with Siri' still ghosted behind the mission thread")
            XCTAssertTrue(el("missionResponseDock").exists)
            // A single-intent goal never posts a plan artifact or an approval turn.
            XCTAssertFalse(option("start-shopping").exists,
                           "the removed plan-approval turn resurfaced for a single-intent goal")
        } else if app.staticTexts["composerDecline"].exists || el("composerDecline").exists {
            snap("03-declined")
            XCTFail("premium jasmine tea was incorrectly declined")
        } else {
            snap("03-thread-timeout")
            XCTFail("Mission thread never appeared")
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

    // MARK: - direct-mission guarantees (live)

    private func textContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Every element carrying the dock's working identifier. `RefinementBar` collapses that status
    /// line into a single accessibility element, so this is expected to hold exactly one — which
    /// the mid-gather test asserts, because when it held two (a `Label`'s icon and its title both
    /// inheriting the identifier) every query below silently resolved to the icon.
    private var dockWorkingElements: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "missionResponseWorking")
    }

    /// How many elements carried the working identifier the last time one was on screen. Recorded
    /// *inside* the poll below, because the working state is transient: re-querying it after the
    /// wait returns races the gather finishing and reads 0.
    private var observedDockWorkingCount = 0

    /// Waits for the dock's working label to carry `question` — the only trustworthy signal for
    /// *which* working turn free text will answer right now.
    ///
    /// Matches on the identifier and reads `label` off the element, rather than folding the text
    /// into the query. A compound `identifier == … AND label CONTAINS …` predicate does not
    /// reliably resolve here — measured on iOS 27: with "Searching the shops…" on screen, a
    /// `label CONTAINS` query over the same hierarchy returned 0 matches — so the original wait
    /// could expire after a full 120s while the state it wanted was plainly visible.
    private func waitForDockWorking(_ question: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = dockWorkingElements.count
            if matches > 0 { observedDockWorkingCount = matches }
            let working = dockWorkingElements.firstMatch
            if working.exists, working.label.localizedCaseInsensitiveContains(question) {
                NSLog("CRUMB-JOURNEY dock working=\(working.label) matches=\(observedDockWorkingCount)")
                return true
            }
            usleep(200_000)
        } while Date() < deadline
        NSLog("CRUMB-JOURNEY dock working never carried '\(question)'")
        return false
    }

    /// Launches to the Missions composer (skipping onboarding when it appears) and sends `goal`.
    @MainActor
    private func launchAndSend(goal: String) {
        app.launch()
        _ = el("onboardingSkip").waitForExistence(timeout: 20)
        var skip = app.buttons["onboardingSkip"]
        if !skip.exists { skip = app.buttons["Skip"] }
        waitTap(skip, 5, "onboardingSkip")
        XCTAssertTrue(el("missionResponseDock").waitForExistence(timeout: 15))
        let field = el("missionResponseField")
        XCTAssertTrue(waitTap(field, 10, "missionResponseField"), "composer field is unavailable")
        field.typeText(goal)
        XCTAssertTrue(waitTap(el("missionResponseSend"), 5, "missionResponseSend"), "send is unavailable")
    }

    /// Free text typed while the live gather is still searching must never cancel it or wedge the
    /// thread — it buffers and applies as a refinement the moment the picks land.
    @MainActor
    func testMidGatherRefinementBuffersAndApplies() {
        launchAndSend(goal: "premium jasmine tea")
        XCTAssertTrue(el("MissionThreadScreen").waitForExistence(timeout: 60))
        snap("mid-01-thread")

        // The thread mounts on "Starting your mission…" — the *planning* turn, where free text
        // deliberately replaces the goal (there is no mission to refine yet). Only the gather's
        // question buffers, so wait for the dock to say it is searching before typing; how long
        // that takes is the live on-device planner's business, not this test's.
        XCTAssertTrue(waitForDockWorking("Searching the shops", timeout: 120),
                      "the gather never took over the dock — planning stalled or the mission declined")
        // The defect this test spent its life tripping over: the working status must be exactly ONE
        // accessibility element. At two — a `Label`'s icon and its title both carrying the
        // identifier — every query for it is a coin flip, and VoiceOver reads a decorative symbol
        // as its own stop. This reads the count observed *during* the wait, not a fresh query: the
        // state is gone by now on a fast gather.
        XCTAssertEqual(observedDockWorkingCount, 1,
                       "missionResponseWorking must be one a11y element, saw \(observedDockWorkingCount)")
        snap("mid-01b-searching")

        // The dock stays conversational during the search — type the refinement now.
        let field = el("missionResponseField")
        XCTAssertTrue(waitTap(field, 15, "mid-gather response field"))
        field.typeText("under $50")
        XCTAssertTrue(waitTap(el("missionResponseSend"), 5, "send mid-gather refinement"))
        snap("mid-02-sent")

        // Buffered (search still running) or applied directly (deck already settled) — either is
        // wedge-free; a live gather is normally slow enough that the buffered ack shows first.
        let ack = textContaining("as soon as the picks land")
        let applied = textContaining("updated the picks")
        XCTAssertTrue(ack.waitForExistence(timeout: 5) || applied.waitForExistence(timeout: 90),
                      "mid-gather text produced neither the buffered ack nor an applied refinement")
        if ack.exists { snap("mid-03-buffered-ack") }

        XCTAssertTrue(applied.waitForExistence(timeout: 180),
                      "the refinement never applied — the mid-gather wedge is back")
        XCTAssertTrue(option("add").waitForExistence(timeout: 30),
                      "no actionable product question after the buffered refinement")
        snap("mid-04-applied")
    }

    /// A non-shopping goal declines gracefully in the thread — the guided triage (or its
    /// heuristic floor) must catch it before any search runs.
    @MainActor
    func testNonShoppingGoalDeclines() {
        launchAndSend(goal: "what is the weather?")
        XCTAssertTrue(el("MissionThreadScreen").waitForExistence(timeout: 60))

        let declined = textContaining("What would you like to shop for instead?")
        XCTAssertTrue(declined.waitForExistence(timeout: 60),
                      "non-shopping goal was not declined")
        XCTAssertFalse(option("add").exists, "a weather question produced a product deck")
        snap("decline-01")
    }
}
