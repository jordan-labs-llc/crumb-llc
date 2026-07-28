import XCTest

/// Coverage for the pinned kit header — the mission screen's deliverable.
///
/// The header replaced an itemised kit card that sat mid-feed and scrolled away, so what a person is
/// about to buy and what it costs are now always on screen. Most of its design lives in the three
/// cases where it deliberately says *less*, and those are what this suite pins: they are exactly the
/// rules a later change is most likely to "tidy up" into a header that is always full.
///
/// Timeouts are generous throughout. The `kit` fixture deals a real deck through the on-device model,
/// which routinely takes tens of seconds to settle — the mission thread appears long before the kit
/// inside it does, so every assertion about a populated header has to wait for the kit rather than for
/// the screen.
final class MissionKitHeaderUITests: XCTestCase {

    /// Long enough for the on-device model to settle a deck on a busy host.
    private let settleTimeout: TimeInterval = 120

    @MainActor
    private func launch(
        _ mode: String,
        contentSize: String = "UICTContentSizeCategoryL"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = mode
        // The simulator defaults to an accessibility content size, which is itself one of the states
        // under test. Pin the size explicitly so each test describes the layout it means to.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "MissionThreadScreen").firstMatch
                .waitForExistence(timeout: 60),
            "Mission thread never appeared"
        )
        return app
    }

    @MainActor
    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "missionKitHeader").firstMatch
    }

    /// The header once it actually holds money — i.e. once the gather has settled and something is
    /// kept. Waiting on this is how a test waits for the deliverable to exist.
    @MainActor
    private func fundedHeader(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                  argumentArray: ["missionKitHeader", "$"]))
            .firstMatch
    }

    @MainActor
    private func settledPicks(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", argumentArray: ["missionSettledPick."]))
    }

    @MainActor
    func testHeaderStatesTheDeliverableOnceThereIsOne() {
        let app = launch("kit")
        XCTAssertTrue(fundedHeader(app).waitForExistence(timeout: settleTimeout),
                      "The kit never reached the header. Label: \(header(app).label)")

        let label = header(app).label
        // The two facts the header exists to keep on screen.
        XCTAssertTrue(label.contains("$"), "Header did not state the subtotal: \(label)")
        XCTAssertTrue(label.contains("kept"), "Header did not state what was kept: \(label)")
        // The pour-over fixture spans three merchants, which under UCP is three independent orders.
        XCTAssertTrue(label.contains("shops"), "Header did not state the shop spread: \(label)")
    }

    @MainActor
    func testHeaderShowsNoMoneyBeforeAnythingIsKept() {
        // `conversation-plan` stops at the plan and never gathers, so this is a stable empty kit
        // rather than a race against one being filled.
        let app = launch("conversation-plan")
        XCTAssertTrue(header(app).waitForExistence(timeout: 30))
        let label = header(app).label

        // A `$0.00` subtotal presented as an achievement is the empty-screen void one screen deeper.
        XCTAssertFalse(label.contains("$"), "Header showed money with an empty kit: \(label)")
        // It states the shape of the work instead, so the space is not simply blank.
        XCTAssertTrue(label.contains("parts"), "Header did not state the plan's shape: \(label)")
        XCTAssertTrue(label.contains("nothing kept yet"),
                      "Header did not say the kit is still empty: \(label)")
        // One shop is not a fact worth a slot, and zero certainly isn't.
        XCTAssertFalse(label.contains("shops"), "Header claimed a shop spread with an empty kit: \(label)")
    }

    @MainActor
    func testHeaderKeepsTheLiveDecisionOnScreenAtAccessibilitySizes() {
        let app = launch("kit", contentSize: "UICTContentSizeCategoryAccessibilityXL")
        XCTAssertTrue(fundedHeader(app).waitForExistence(timeout: settleTimeout),
                      "The kit never reached the header at an accessibility size")

        // The header still states the deliverable…
        XCTAssertTrue(header(app).label.contains("kept"), "Header stopped stating the kit at AX size")
        // …but must not have grown into the one thing on screen that can be acted on. The dock is what
        // answers the live question, so if the header has eaten it the screen is unusable.
        let dock = app.descendants(matching: .any).matching(identifier: "missionResponseDock").firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 30), "The header displaced the response dock at AX size")
        XCTAssertTrue(dock.frame.height > 0, "The dock collapsed to nothing at AX size")
        XCTAssertTrue(
            header(app).frame.maxY < dock.frame.minY,
            "Header and dock overlap at AX size — header \(header(app).frame), dock \(dock.frame)"
        )
    }

    @MainActor
    func testTheRunLogIsGoneFromTheConversation() {
        let app = launch("kit")
        // Wait for a mission that has actually done the work whose narration used to be on screen.
        XCTAssertTrue(fundedHeader(app).waitForExistence(timeout: settleTimeout),
                      "The kit never settled, so there was no run log to be absent")

        // The receipts that used to narrate every internal step. Their results are on screen — the
        // header states the count and subtotal, and every pick is a settled row — so the narration is
        // not rendered. It remains in the persisted timeline and reaches History untouched.
        for receipt in ["options so far", "picks ready to explore"] {
            let line = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", receipt))
                .firstMatch
            XCTAssertFalse(line.exists, "The conversation still reads a run-log receipt: \(receipt)")
        }

        // What replaced them: each answered pick as one row that states its own verdict — now
        // folded behind "What Crumb did", because the screen leads with the open decision rather
        // than the record of how it got here. The rows still exist, and still say what they say.
        let disclosure = app.descendants(matching: .any)
            .matching(identifier: "missionHistoryDisclosure").firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 30),
                      "Answered picks were not folded into a 'What Crumb did' disclosure")
        disclosure.tap()

        XCTAssertTrue(settledPicks(app).firstMatch.waitForExistence(timeout: 30),
                      "Answered picks did not collapse into settled rows")
        XCTAssertTrue(settledPicks(app).count >= 2,
                      "Expected several settled picks, found \(settledPicks(app).count)")
    }
}
