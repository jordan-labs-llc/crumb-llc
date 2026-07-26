import XCTest

/// Deterministic end-to-end coverage for the conversation-first mission surface.
///
/// The feed is read-only. Every plan, product, refinement, recovery, and cart response is submitted
/// through `missionResponseDock`. Persistence uses an isolated on-disk SwiftData store so relaunch
/// proves that the exact frozen product question returns without replaying the catalog.
final class MissionThreadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CRUMB_UITEST"] = "1"
        app.launchEnvironment["CRUMB_UITEST_PERSISTENT_MOCK"] = "1"
        app.launchEnvironment["CRUMB_UITEST_RESET_STORE"] = "1"
        app.launchEnvironment["CRUMB_UITEST_SEED_PROFILE"] = "1"
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func option(_ identifier: String) -> XCUIElement {
        element("missionResponseOption.\(identifier)")
    }

    @MainActor
    private func dockOption(_ identifier: String) -> XCUIElement {
        element("missionResponseDock").descendants(matching: .any)
            .matching(identifier: "missionResponseOption.\(identifier)").firstMatch
    }

    @MainActor
    private func artifact(prefix: String, excluding identifier: String? = nil) -> XCUIElement {
        var format = "identifier BEGINSWITH %@"
        var arguments: [Any] = [prefix]
        if let identifier {
            format += " AND identifier != %@"
            arguments.append(identifier)
        }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: format, argumentArray: arguments))
            .firstMatch
    }

    @MainActor
    private func textContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name).tree.txt"
        tree.lifetime = .keepAlways
        add(tree)
        NSLog("CRUMB-CONVERSATION snap=\(name)")
    }

    @discardableResult
    @MainActor
    private func waitTap(
        _ target: XCUIElement,
        timeout: TimeInterval = 10,
        _ description: String
    ) -> Bool {
        guard target.waitForExistence(timeout: timeout) else {
            XCTFail("Missing \(description)")
            return false
        }
        let deadline = Date().addingTimeInterval(5)
        while !target.isHittable && Date() < deadline { usleep(200_000) }
        guard target.isHittable else {
            XCTFail("\(description) exists but is not hittable")
            return false
        }
        target.tap()
        return true
    }

    @MainActor
    private func assertSoleMissionInput(
        expectsEditableField: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element("missionResponseDock").exists, file: file, line: line)
        XCTAssertEqual(element("missionResponseField").exists, expectsEditableField, file: file, line: line)
        XCTAssertLessThanOrEqual(app.textFields.count, 1, "Mission must expose zero or one editable field", file: file, line: line)
        for removed in [
            "curateButton", "addButton", "skipButton", "kitTray", "threadRetryButton",
            "threadPersistenceRetryButton", "addPartField", "threadComposerField",
            "composerField", "planButton",
        ] {
            XCTAssertFalse(element(removed).exists, "Legacy action remains outside the dock: \(removed)", file: file, line: line)
        }
    }

    /// Reaches the first frozen product question. Direct missions: sending the goal starts the
    /// search immediately — no plan approval turn — so the first decision point IS the product
    /// question. Returns that product artifact's stable accessibility identifier.
    @MainActor
    private func launchToFirstProductQuestion() -> String {
        app.launch()
        if app.buttons["onboardingSkip"].waitForExistence(timeout: 3) {
            app.buttons["onboardingSkip"].tap()
        }
        XCTAssertTrue(element("MissionsScreen").waitForExistence(timeout: 20))

        let goal = "Set up my pour-over corner"
        XCTAssertTrue(element("missionResponseDock").waitForExistence(timeout: 10))
        let missionField = element("missionResponseField")
        XCTAssertTrue(waitTap(missionField, timeout: 10, "mission composer"))
        missionField.typeText(goal)
        XCTAssertTrue(waitTap(element("missionResponseSend"), timeout: 10, "send mission"))

        XCTAssertTrue(element("MissionThreadScreen").waitForExistence(timeout: 30))
        // No plan-approval turn ever appears between the goal and the deck.
        XCTAssertFalse(option("start-shopping").exists, "The removed plan-approval turn resurfaced")
        let product = artifact(prefix: "missionArtifact.product.")
        XCTAssertTrue(product.waitForExistence(timeout: 90), "First frozen product question never appeared")
        for id in ["add", "skip", "show-another"] {
            XCTAssertTrue(option(id).waitForExistence(timeout: 10), "Missing dock product response: \(id)")
        }
        assertSoleMissionInput()
        snap("conversation-02-product-question")
        return product.identifier
    }

    @MainActor
    func testTypedProductWriteActsImmediately() {
        _ = launchToFirstProductQuestion()

        let field = element("missionResponseField")
        XCTAssertTrue(waitTap(field, timeout: 10, "product response field"))
        field.typeText("add it")
        XCTAssertTrue(waitTap(element("missionResponseSend"), timeout: 5, "send product request"))

        // The typed answer commits like the chip — no confirmation detour, and the composer's
        // editable field never disappears.
        XCTAssertTrue(textContaining("Added").waitForExistence(timeout: 10),
                      "Typed 'add it' did not commit the frozen product")
        XCTAssertFalse(dockOption("cancel").exists, "The removed confirmation turn resurfaced")
        XCTAssertTrue(dockOption("add").waitForExistence(timeout: 10),
                      "The conversation did not advance to the next product question")
        assertSoleMissionInput()
        snap("conversation-typed-add")
    }

    @MainActor
    func testFirstProductQuestionMilestone() {
        _ = launchToFirstProductQuestion()
    }

    @MainActor
    func testDockOnlyMissionJourneyAndExactQuestionResume() {
        let pendingProductID = launchToFirstProductQuestion()

        // The exact frozen question must survive process death. Continue may not replay or retarget it.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "CRUMB_UITEST_RESET_STORE")
        app.launch()
        XCTAssertTrue(element("MissionsScreen").waitForExistence(timeout: 20))
        let continueMission = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'Continue'"))
            .firstMatch
        XCTAssertTrue(waitTap(continueMission, timeout: 15, "Continue mission"))
        XCTAssertTrue(element("MissionThreadScreen").waitForExistence(timeout: 20))
        XCTAssertTrue(element(pendingProductID).waitForExistence(timeout: 15),
                      "Relaunch replaced the pending product snapshot")
        for id in ["add", "skip", "show-another"] {
            XCTAssertTrue(option(id).waitForExistence(timeout: 10), "Relaunch lost product option \(id)")
        }
        assertSoleMissionInput()
        snap("conversation-05-resumed-question")

        // Show another and Skip are answers in the same dock, never controls on the product card.
        XCTAssertTrue(waitTap(option("show-another"), timeout: 10, "Show another"))
        let secondProduct = artifact(prefix: "missionArtifact.product.", excluding: pendingProductID)
        XCTAssertTrue(secondProduct.waitForExistence(timeout: 20), "Show another did not present another product")
        XCTAssertTrue(waitTap(option("skip"), timeout: 10, "Skip"))
        XCTAssertTrue(textContaining("Skipped").waitForExistence(timeout: 10))

        // Free text also stays in the dock and produces a normal user turn before reworking.
        let responseField = element("missionResponseField")
        XCTAssertTrue(waitTap(responseField, timeout: 10, "refinement field"))
        responseField.typeText("Make the remaining picks cheaper")
        XCTAssertTrue(waitTap(element("missionResponseSend"), timeout: 5, "send refinement"))
        XCTAssertTrue(textContaining("updated the picks").waitForExistence(timeout: 60),
                      "Typed refinement never completed")
        XCTAssertTrue(option("add").waitForExistence(timeout: 20))
        assertSoleMissionInput()
        snap("conversation-06-refined")

        XCTAssertTrue(waitTap(option("add"), timeout: 10, "Add"))
        XCTAssertTrue(textContaining("Added").waitForExistence(timeout: 10))

        // Exhaust the remaining product questions through the dock until the kit-review question.
        for _ in 0..<20 {
            if option("review-cart").waitForExistence(timeout: 1) { break }
            XCTAssertTrue(waitTap(option("skip"), timeout: 10, "Skip remaining product"))
        }
        XCTAssertTrue(option("review-cart").waitForExistence(timeout: 10),
                      "Deck exhaustion did not produce a cart-review question")
        XCTAssertTrue(artifact(prefix: "missionArtifact.kit.").waitForExistence(timeout: 10))
        assertSoleMissionInput()
        snap("conversation-07-kit-question")

        XCTAssertTrue(waitTap(option("review-cart"), timeout: 10, "Review cart"))
        XCTAssertTrue(element("CartScreen").waitForExistence(timeout: 20),
                      "Dock cart-review answer did not open Cart")
        snap("conversation-08-cart")

        XCTAssertTrue(waitTap(element("backButton"), timeout: 10, "Back from Cart"))
        XCTAssertTrue(element("MissionThreadScreen").waitForExistence(timeout: 20),
                      "Back from Cart did not restore the conversation")
        let jump = element("missionJumpToLatest")
        if jump.waitForExistence(timeout: 3) {
            XCTAssertTrue(waitTap(jump, timeout: 3, "Jump to latest after Cart"))
        } else {
            let feed = element("missionConversationFeed")
            for _ in 0..<8 where !artifact(prefix: "missionArtifact.kit.").exists {
                feed.swipeUp()
            }
        }
        XCTAssertTrue(artifact(prefix: "missionArtifact.kit.").waitForExistence(timeout: 5),
                      "Cart round-trip lost the frozen kit turn")
        for id in ["review-cart", "find-more", "end"] {
            XCTAssertTrue(option(id).waitForExistence(timeout: 5),
                          "Cart round-trip did not restore durable kit response: \(id)")
        }
        assertSoleMissionInput()
        snap("conversation-09-cart-return")

        // A useful kit remains an incomplete, resumable conversation until the person explicitly
        // ends it. Relaunch must restore the exact kit question rather than treating Cart as terminal.
        app.terminate()
        app.launch()
        XCTAssertTrue(element("MissionsScreen").waitForExistence(timeout: 20))
        let resumeKit = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] 'Continue'"))
            .firstMatch
        XCTAssertTrue(waitTap(resumeKit, timeout: 15, "Continue kit question"))
        XCTAssertTrue(element("MissionThreadScreen").waitForExistence(timeout: 20))
        XCTAssertTrue(option("review-cart").waitForExistence(timeout: 10))
        XCTAssertTrue(option("find-more").exists)
        XCTAssertTrue(option("end").exists)
        snap("conversation-10-resumed-kit-question")
    }

    @MainActor
    func testProductQuestionAtAccessibilityXXXL() {
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "conversation-product"
        app.launchEnvironment["CRUMB_MISSION"] = "coffee"
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(element("MissionThreadScreen").waitForExistence(timeout: 30))
        XCTAssertTrue(artifact(prefix: "missionArtifact.product.").waitForExistence(timeout: 90))
        let pendingQuestion = textContaining("How does this one look")
        XCTAssertTrue(pendingQuestion.waitForExistence(timeout: 10),
                      "AX cold mount did not reveal the pending product question")
        XCTAssertTrue(pendingQuestion.isHittable,
                      "AX pending product question exists only in offscreen scrollback")
        XCTAssertTrue(element("missionResponseDock").waitForExistence(timeout: 10))
        XCTAssertTrue(element("missionResponseField").exists)
        XCTAssertTrue(waitTap(
            element("missionResponseChoiceDisclosure"),
            timeout: 10,
            "expand accessibility responses"
        ))
        XCTAssertTrue(element("missionResponseChoiceSheet").waitForExistence(timeout: 10))
        XCTAssertTrue(element("missionResponseChoiceQuestion").exists)
        for id in ["add", "skip", "show-another"] {
            let option = element("missionResponseOption.\(id)")
            XCTAssertTrue(option.exists, "AX composer expansion lost product response: \(id)")
            XCTAssertTrue(option.isHittable, "AX composer response is not actionable: \(id)")
        }
        assertSoleMissionInput()
        snap("conversation-axxxl-product-question")
    }
}
