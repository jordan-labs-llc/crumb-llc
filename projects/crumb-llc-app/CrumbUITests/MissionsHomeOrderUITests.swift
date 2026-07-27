import XCTest

/// Reading-order and semantics coverage for the Missions landing page.
///
/// **This suite deliberately replaces the contract it used to pin.** The previous version asserted that
/// the greeting was read *after* the missions and that the newest mission sat nearest the dock — the
/// bottom-anchored, oldest-first column. That anchor bought proximity between the question and the field
/// and paid for it with a half-empty screen and a scan order that met the stalest mission first. Home
/// now reads from the top: one hero for the most recently touched mission, then a split by who owes the
/// next move, with the dock collapsed to a single line.
///
/// The seeded `missions-many` fixture (8 threads, newest first) resolves to:
/// hero = "Find premium jasmine tea" (kept items), 5 rows waiting on you (2 of them stalled), and
/// 2 rows where Crumb is working.
final class MissionsHomeOrderUITests: XCTestCase {

    @MainActor
    private func launchSeededHome(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = mode
        // The simulator defaults to an accessibility content size, which routes the dock's starter
        // chips into a disclosure menu and changes what is on screen. Pin a normal size so these
        // assertions describe the layout being tested rather than the host's setting.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "MissionsScreen").firstMatch
                .waitForExistence(timeout: 30),
            "Missions landing page never appeared"
        )
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A button inside a presented `confirmationDialog`. The system renders more than one element
    /// per action (the sheet's own button plus a backing representation), so a bare subscript
    /// throws "multiple matching elements" — take the one a person could actually tap.
    @MainActor
    private func dialogButton(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: identifier)
        for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    /// Every non-hero mission row, in visual top-to-bottom order.
    @MainActor
    private func continueRows(_ app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'continueThread.'"))
            .allElementsBoundByIndex
            .filter(\.exists)
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor
    func testHeroIsTheMostRecentMissionAndIsReadBeforeEveryOtherRow() {
        let app = launchSeededHome("missions-many")

        let hero = element(app, "homeHero")
        XCTAssertTrue(hero.exists, "Home lost its hero card")

        // The seed stamps "Find premium jasmine tea" as the most recently updated thread. One rule,
        // no special-casing on phase: the most recent mission always takes the hero slot.
        XCTAssertTrue(
            hero.label.contains("Find premium jasmine tea"),
            "The hero must be the most recently touched mission, found '\(hero.label)'"
        )
        // It has kept items, so the hero states the deliverable rather than the phase.
        XCTAssertTrue(
            hero.label.contains("kept"),
            "A hero with kept items must state them, found '\(hero.label)'"
        )

        let rows = continueRows(app)
        XCTAssertGreaterThan(rows.count, 1, "Seeded home should render several mission rows")
        for row in rows {
            XCTAssertGreaterThan(
                row.frame.minY, hero.frame.minY,
                "Row '\(row.identifier)' is above the hero; the hero must be read first"
            )
        }
    }

    @MainActor
    func testSectionsSplitByWhoOwesTheNextMoveAndStateTheirDepth() {
        let app = launchSeededHome("missions-many")

        let waiting = element(app, "homeWaitingSection")
        let working = element(app, "homeWorkingSection")
        XCTAssertTrue(waiting.exists, "Home lost the 'waiting on you' section")
        XCTAssertTrue(working.exists, "Home lost the 'Crumb is working' section")

        // Your move comes before Crumb's move.
        XCTAssertLessThan(
            waiting.frame.minY, working.frame.minY,
            "'Waiting on you' must be read before 'Crumb is working'"
        )

        // The count is what made eight missions and twelve missions render the same screen: depth has
        // to be a number, not something inferred from a clipped card.
        XCTAssertTrue(
            app.staticTexts["Waiting on you, 5"].exists,
            "The waiting section must announce how many missions are in it"
        )
        XCTAssertTrue(
            app.staticTexts["Crumb is working, 2"].exists,
            "The working section must announce how many missions are in it"
        )
    }

    @MainActor
    func testEveryRowAnnouncesContinuationItsReasonAndItsAge() {
        let app = launchSeededHome("missions-many")

        for row in continueRows(app) {
            XCTAssertTrue(
                row.label.hasPrefix("Continue "),
                "Row '\(row.identifier)' no longer announces itself as a continuation: '\(row.label)'"
            )
            // Recency is the only thing the sort encodes and it used to be invisible on every row, so
            // "Searching shops" could equally mean four seconds or four weeks.
            let statesAnAge = ["ago", "Yesterday", "Just now", "Last week"].contains {
                row.label.contains($0)
            }
            XCTAssertTrue(statesAnAge, "Row '\(row.identifier)' states no age: '\(row.label)'")
        }

        let labels = continueRows(app).map(\.label)
        // The five registers are gone. A stall says what stopped it; it never says "Needs attention",
        // and a settled-but-empty deck is never announced as though picks were ready.
        XCTAssertFalse(
            labels.contains { $0.contains("Needs attention") || $0.contains("Picks ready") },
            "A row still uses the retired status vocabulary: \(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("Stopped before it finished") },
            "The seeded failed missions must state that they stopped: \(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("to review") || $0.contains("Ready to shop") },
            "No row announced what is waiting inside it: \(labels)"
        )
    }

    @MainActor
    func testDockCollapsesWhenThereIsWorkAndCarriesTheAskWhenThereIsNot() {
        // Empty: the ask is at full height, with the greeting, the teaching line, the recipient
        // control and the starter chips all present.
        let cold = launchSeededHome("composer")
        XCTAssertTrue(
            cold.staticTexts["What are we shopping for?"].exists,
            "An empty Home must still ask the question"
        )
        XCTAssertTrue(
            cold.staticTexts["I'll search the shops and bring back picks worth keeping."].exists,
            "A first-run visitor should still be told what the field does"
        )
        XCTAssertTrue(
            element(cold, "newMissionSuggestions").exists,
            "An empty Home must offer starters"
        )
        XCTAssertTrue(
            element(cold, "composerRecipientAccessory").exists,
            "An empty Home must expose who the mission is for"
        )
        XCTAssertFalse(
            element(cold, "homeHero").exists,
            "An empty Home must not render a hero"
        )
        cold.terminate()

        // Populated: all of that retires. The field alone carries the invitation, because the
        // greeting and chips would be competing with content that earned the space.
        let busy = launchSeededHome("missions-many")
        // Note this passes for a subtler reason than it used to: a populated Home *does* carry a
        // short-form ask, but it reads "What else are we shopping for?" — different words, no display
        // type, no teaching line, and none of the dock furniture the collapse retires. The full
        // greeting is still gone. See `testSparseHomeEndsWithAnInvitationRatherThanDeadSpace`.
        XCTAssertFalse(
            busy.staticTexts["What are we shopping for?"].exists,
            "The greeting must retire once there is work on screen"
        )
        XCTAssertFalse(
            element(busy, "newMissionSuggestions").exists,
            "The starter chips must retire once there is work on screen"
        )
        XCTAssertTrue(
            element(busy, "missionResponseDock").exists,
            "Collapsing the dock must not remove it"
        )
        XCTAssertTrue(
            busy.textFields["Start something new…"].exists
                || busy.textViews["Start something new…"].exists,
            "The collapsed dock must carry the invitation in its placeholder"
        )
    }

    /// One or two missions leave most of the screen empty — top-anchored column, collapsed dock, and no
    /// auto-focus (the dock only claims the keyboard on an empty Home). A short-form ask is pushed to
    /// the floor by a spacer that can only expand when the list is short, so the leftover space is
    /// bounded by content instead of trailing off.
    @MainActor
    func testSparseHomeEndsWithAnInvitationRatherThanDeadSpace() {
        let sparse = launchSeededHome("missions-one")

        let ask = element(sparse, "homeFollowUpAsk")
        let hero = element(sparse, "homeHero")
        let dock = element(sparse, "missionResponseDock")
        XCTAssertTrue(ask.exists, "A sparse Home must end with an invitation")
        XCTAssertGreaterThan(ask.frame.minY, hero.frame.maxY,
                             "The ask belongs below the hero, not competing with it")
        XCTAssertLessThan(ask.frame.maxY, dock.frame.minY,
                          "The ask must sit above the dock, not behind it")

        // It has to actually reach the floor — that is the whole point. Allow a generous margin for
        // the content padding between the two.
        let gapToDock = dock.frame.minY - ask.frame.maxY
        XCTAssertLessThan(gapToDock, 120,
                          "The ask is stranded \(Int(gapToDock))pt above the dock instead of resting on it")
        sparse.terminate()

        // With the viewport full the spacer collapses to nothing, so the ask follows the last row
        // instead of being injected mid-list. It stays in the hierarchy, below the fold.
        let busy = launchSeededHome("missions-many")
        let busyAsk = element(busy, "homeFollowUpAsk")
        XCTAssertTrue(busyAsk.exists, "The ask must still be reachable when the list is long")
        let lastRow = continueRows(busy).last
        XCTAssertNotNil(lastRow)
        XCTAssertGreaterThan(busyAsk.frame.minY, lastRow!.frame.minY,
                             "With a full viewport the ask must come after the missions, not before")
    }

    /// Home's hero renders its own frozen question and answers it without opening the mission first.
    ///
    /// Home used to have exactly one verb — go to the mission — so it announced that a decision was
    /// needed and then sent you elsewhere to make it. These assertions are about the answer actually
    /// committing, not about the buttons rendering: a screenshot proves the latter and nothing else.
    @MainActor
    func testHeroQuestionIsAnsweredWithoutOpeningTheMission() {
        let app = launchSeededHome("missions-inbox")

        let hero = element(app, "homeHero")
        XCTAssertTrue(hero.exists)
        // The question is quoted verbatim, because these options resolve that exact frozen question.
        XCTAssertTrue(
            app.staticTexts["“That turn didn’t finish. What next?”"].exists,
            "The hero must quote the question its options answer"
        )

        let retry = app.buttons["homeHeroOption.retry"]
        let cancel = app.buttons["homeHeroOption.cancel"]
        XCTAssertTrue(retry.exists, "The hero must offer the interaction's own options")
        XCTAssertTrue(cancel.exists)
        // Options replace the navigation CTA rather than sitting alongside it — two competing primary
        // actions on one card is how a person ends up tapping the wrong one.
        XCTAssertFalse(
            element(app, "homeHeroCallToAction").exists,
            "An answerable hero must not also show its navigation CTA"
        )

        // Cancel ends the whole mission, so it is no longer a one-tap answer. It was rewritten from
        // "tap and it commits" when the confirmation landed: a destructive option that committed on
        // the first tap is the behaviour being fixed, not a contract worth preserving.
        cancel.tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "missionEndConfirm").firstMatch
                .waitForExistence(timeout: 10),
            "A destructive option must confirm before it commits"
        )
        XCTAssertTrue(
            retry.exists,
            "The question must survive an unconfirmed end — nothing has been answered yet"
        )
        dialogButton(app, "missionEndConfirm").tap()

        // The answer committed: the question's epoch ended, so its options are gone. This is the
        // assertion that distinguishes a working control from a decorative one.
        XCTAssertTrue(
            retry.waitForNonExistence(timeout: 10),
            "Confirming must resolve the interaction, retiring its options"
        )
    }

    /// The other half of the confirmation: backing out must leave the mission exactly as it was.
    /// A confirmation that ends the mission anyway is worse than none, because it teaches people
    /// the dialog is noise.
    @MainActor
    func testDismissingTheEndConfirmationLeavesTheMissionAlone() {
        let app = launchSeededHome("missions-inbox")

        let retry = app.buttons["homeHeroOption.retry"]
        let cancel = app.buttons["homeHeroOption.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))

        cancel.tap()
        let confirm = app.buttons.matching(identifier: "missionEndConfirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The end confirmation never appeared")

        // Back out the way the platform offers it. Anchored to the hero card, the system presents
        // this dialog as a popover, which omits the `.cancel` action entirely — tapping outside is
        // the dismissal. So the "Keep shopping" button is queried where it does render (a sheet)
        // and a tap well above the popover is used here.
        let keepShopping = app.buttons.matching(NSPredicate(format: "label == %@", "Keep shopping"))
        if keepShopping.firstMatch.exists {
            keepShopping.firstMatch.tap()
        } else {
            element(app, "PopoverDismissRegion")
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                .tap()
        }

        XCTAssertTrue(
            confirm.waitForNonExistence(timeout: 10),
            "Backing out must dismiss the confirmation"
        )
        XCTAssertTrue(retry.exists, "Backing out must leave the frozen question answerable")
        XCTAssertTrue(cancel.exists, "Backing out must leave the mission on Home")
    }

    /// Demoting the option must not hide it. The quiet treatment is only defensible if the control
    /// is still there, still last, and still reachable — including for VoiceOver, which is why it
    /// keeps the identifier and the 44pt target the capsule had.
    ///
    /// The geometry half of the demotion is asserted in `MissionThreadUITests`, where the peer
    /// chips share a horizontal row and leaving that row is observable. Home stacked them
    /// vertically already, so an ordering assertion here would pass against the old layout too.
    @MainActor
    func testDemotedEndingStaysReachable() {
        let app = launchSeededHome("missions-inbox")

        let retry = app.buttons["homeHeroOption.retry"]
        let cancel = app.buttons["homeHeroOption.cancel"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.exists, "Demoting the option must not remove it")
        XCTAssertTrue(cancel.isHittable, "Demoting the option must not make it unreachable")
        XCTAssertGreaterThan(
            cancel.frame.minY, retry.frame.minY,
            "The exit belongs after the answers"
        )
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "The tap target must survive the demotion")
    }

    /// Answering an option that *starts work* keeps you on Home while that work runs.
    ///
    /// `runRetry` → `startCurating()` only launches a background task; the route into the mission is set
    /// later, inside `beginCuration`, once the gather resolves. So the immediate outcome of tapping
    /// "Retry" is that the question retires and Home stays put — which is the whole claim of answering in
    /// place, and worth pinning because it depends on `startCurating` not navigating eagerly.
    ///
    /// This deliberately does NOT assert the eventual route. That waits on the on-device model, whose
    /// settle time is long and variable, and a test that races it would be flaky rather than useful.
    @MainActor
    func testAnsweringAnOptionThatStartsWorkKeepsYouOnHome() {
        let app = launchSeededHome("missions-inbox")

        let retry = app.buttons["homeHeroOption.retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()

        XCTAssertTrue(
            retry.waitForNonExistence(timeout: 10),
            "Answering must resolve the interaction, retiring its options"
        )
        XCTAssertTrue(
            element(app, "MissionsScreen").exists,
            "Starting work from Home must not navigate away from Home to do it"
        )
        XCTAssertTrue(element(app, "homeHero").exists, "The hero must survive answering its own question")
    }

    /// A hero with no options — or none at all — must not pretend to be answerable.
    @MainActor
    func testHeroWithoutOptionsFallsBackToOpeningTheMission() {
        let app = launchSeededHome("missions-stalled")

        XCTAssertTrue(element(app, "homeHero").exists)
        XCTAssertTrue(
            element(app, "homeHeroCallToAction").exists,
            "Without an answerable question the hero must offer the mission instead"
        )
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'homeHeroOption.'")).count, 0,
            "A hero with no installed interaction must not render option buttons"
        )
    }

    @MainActor
    func testStalledMissionsAreDistinguishableFromReadyOnes() {
        let app = launchSeededHome("missions-many")

        // A failed mission used to get the same card, the same green arrow and the same weight as a
        // finished one — the only difference was two words that did not say what went wrong.
        let stalled = continueRows(app).filter { $0.label.contains("Stopped before it finished") }
        XCTAssertEqual(stalled.count, 2, "The seed has two failed missions among the non-hero rows")

        let ready = continueRows(app).filter {
            $0.label.contains("to review") || $0.label.contains("Ready to shop")
        }
        XCTAssertFalse(ready.isEmpty, "The seed should also produce ready rows to contrast against")
        for row in stalled {
            XCTAssertFalse(
                ready.contains { $0.identifier == row.identifier },
                "A row is being reported as both stalled and ready: '\(row.label)'"
            )
        }
    }
}
