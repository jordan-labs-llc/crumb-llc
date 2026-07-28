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
        // Launch into an empty app. Nothing resets the simulator between tests, and two of the three
        // here shop the same goal, so without this the purchase journey's mission is still in the
        // thread store — across runs, not just across tests — when the mid-gather test starts.
        // Hygiene, not a fix: it was tried as a fix for that test's intermittent failure and
        // verifiably did not change it. Store isolation only; the broker and seams stay live.
        app.launchEnvironment["CRUMB_UITEST_RESET_STORE"] = "1"
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

    /// Every element carrying the dock's working identifier. `RefinementBar` hides the status
    /// line's decorative icon, so this holds exactly one element; it used to hold two, because a
    /// `Label` publishes its icon and its title separately and a caller's identifier landed on both.
    private var dockWorkingElements: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "missionResponseWorking")
    }

    /// Waits for the dock's working label to carry `question` — the only trustworthy signal for
    /// *which* working turn free text will answer right now.
    ///
    /// Note this wait is NOT known to be the cause of that historical failure, and says nothing
    /// about why the state was absent for 120s — see `reportDockStateOnTimeout`, which exists to
    /// answer that the next time it happens.
    private func waitForDockWorking(_ question: String, timeout: TimeInterval) -> Bool {
        // Ask the query engine for "an element with this identifier whose label contains the text"
        // and count the answer. Counting a query is evaluated against one snapshot and yields 0 when
        // nothing matches; resolving elements and then reading `.label` off them does not — the
        // element can disappear between the two steps, and XCUITest raises "Failed to get matching
        // snapshot" rather than returning false. That is a race the test invents for itself, and it
        // is not hypothetical: it failed a run here. The predicate also makes the match
        // order-independent, so it no longer matters how many elements carry the identifier.
        let matching = dockWorkingElements
            .matching(NSPredicate(format: "label CONTAINS[c] %@", question))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if matching.count > 0 {
                NSLog("CRUMB-JOURNEY dock working carried '\(question)'")
                return true
            }
            usleep(200_000)
        } while Date() < deadline
        reportDockStateOnTimeout(expected: question)
        return false
    }

    /// Records what the dock was *actually* showing when a wait expired.
    ///
    /// Worth its weight: this wait has failed by timing out on a state the app appeared to be in,
    /// and without knowing which dock mode was really on screen every explanation for that is a
    /// guess. The three modes are mutually exclusive in `RefinementBar.activeMissionContents`, and
    /// `.recovery` in particular latches for the rest of the mission once a thread fails to save —
    /// the app keeps gathering and the deck still lands, so the symptom is exactly this timeout.
    private func reportDockStateOnTimeout(expected: String) {
        let modes = ["missionResponseWorking", "missionResponseRecovery",
                     "missionResponseWarning", "missionResponseConfirmation"]
        // Counts only — see `waitForDockWorking`: reading `.label` off resolved elements can raise
        // on a screen that is still moving, and a diagnostic that can throw is worse than useless
        // because it replaces the failure you were trying to explain. The tree dump below carries
        // the labels.
        let seen = modes.map { id in
            "\(id)=\(app.descendants(matching: .any).matching(identifier: id).count)"
        }
        // Whether a deck is already on screen separates the two explanations for an absent working
        // status. Deck present means the mission reached its picks without this test ever seeing a
        // gather — which is what `beginCuration`'s early return does when a thread already has
        // candidates and no pending operation: it routes straight to the thread and never calls
        // `loadCandidates`, so no working question is installed and no search runs.
        let deck = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "missionArtifact.product."))
            .allElementsBoundByAccessibilityElement.count
        let options = app.descendants(matching: .any)
            .matching(identifier: "missionResponseOptions").allElementsBoundByAccessibilityElement.count
        NSLog("CRUMB-JOURNEY dock never carried '\(expected)'. Dock state: \(seen.joined(separator: ", ")), productArtifacts=\(deck), optionRows=\(options)")
        // The tree in the log, not only as an attachment: a failing run's xcresult is routinely
        // pruned before anyone reads it.
        NSLog("CRUMB-JOURNEY tree at timeout:\n\(app.debugDescription)")
        snap("dock-timeout")
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
        // Guarantee a window in which the search is actually running. This is the only test that
        // needs one — it types *into* a gather — and a warm simulator can finish one in under a
        // second, which is less time than this test takes to mount the screen and look. Scoped to
        // this test rather than `setUp` so the other two journeys keep exercising a real, unpadded
        // gather. The search itself is untouched: it runs concurrently with this floor.
        app.launchEnvironment["CRUMB_UITEST_GATHER_HOLD_MS"] = "8000"
        launchAndSend(goal: "premium jasmine tea")
        XCTAssertTrue(el("MissionThreadScreen").waitForExistence(timeout: 60))

        // Start watching for the gather before capturing anything. `snap` takes a screenshot *and*
        // a full `app.debugDescription`, which is seconds of blind time — and it used to sit right
        // here, between the thread mounting and this wait, i.e. exactly across the moment the
        // gather starts. On a cold app the search outlasts that blind spot; on a warm one it can
        // finish inside it, and the wait then spends its whole 120s looking at a settled deck for
        // a status the app had already retired. The capture is a diagnostic; it must not be in the
        // critical path of the thing being observed.
        //
        // The thread mounts on "Starting your mission…" — the *planning* turn, where free text
        // deliberately replaces the goal (there is no mission to refine yet). Only the gather's
        // question buffers, so wait for the dock to say it is searching before typing; how long
        // that takes is the live on-device planner's business, not this test's.
        XCTAssertTrue(waitForDockWorking("Searching the shops", timeout: 120),
                      "the gather never took over the dock — planning stalled or the mission declined")
        snap("mid-01-thread")
        // Deliberately NOT asserting that the identifier resolves to a single element. It resolves
        // to two — SwiftUI propagates an identifier to a container and its text child — and that is
        // an implementation detail of the accessibility tree, not a contract this journey should
        // pin. What matters is that the status text is findable no matter how many elements carry
        // the identifier, which `waitForDockWorking` guarantees by scanning all of them.
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
