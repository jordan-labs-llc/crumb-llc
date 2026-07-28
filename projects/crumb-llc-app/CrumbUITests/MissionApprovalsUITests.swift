import XCTest

/// The delegation loop, driven the way a person drives it: set the mode in the dock, read what Crumb
/// did from the receipt, and take it back.
///
/// The point of running this in the simulator rather than only against `AppModel` is that every claim
/// here is about something being *reachable* — a menu that opens, a receipt that expands, an undo
/// that sits in the dock with the ordinary answers. A model-level test can pass with all three
/// stranded off-screen.
final class MissionApprovalsUITests: XCTestCase {

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // A settled multi-part deck with nothing kept — the state where delegation is worth offering.
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "curate"
        // Deterministic seams: the mock catalog and the rule-based curator, so this suite never waits
        // on the on-device model.
        app.launchEnvironment["CRUMB_UITEST_PERSISTENT_MOCK"] = "1"
        // The simulator defaults to an accessibility content size, which collapses the dock's chips
        // into a disclosure and hides the accessory row this test is about.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(element(app, "MissionThreadScreen").waitForExistence(timeout: 60),
                      "Mission thread never appeared")
        return app
    }

    /// Keeps the rendered state with the test run, so a change to this screen can be *looked* at and
    /// not merely asserted about.
    @MainActor
    private func snap(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func first(_ app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", argumentArray: [prefix]))
            .firstMatch
    }

    @MainActor
    private func keptHeader(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@",
                                  argumentArray: ["missionKitHeader", "kept"]))
            .firstMatch
    }

    /// Opens the approvals menu and switches the mission to Auto.
    @MainActor
    private func turnOnAuto(_ app: XCUIApplication) {
        let accessory = element(app, "missionApprovalAccessory")
        XCTAssertTrue(accessory.waitForExistence(timeout: 30),
                      "The approvals control never appeared on a multi-part deck")
        XCTAssertTrue(accessory.label.contains("asks about each pick"),
                      "Approvals did not start in the asking mode: \(accessory.label)")
        accessory.tap()

        let auto = app.buttons["Keep the best fit for each part"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10), "The approvals menu never opened")
        auto.tap()
    }

    @MainActor
    func testAutoKeepsAndReportsWhatItKept() {
        let app = launch()
        snap("01-before-delegating")
        turnOnAuto(app)

        // The receipt is the whole legibility claim: decisions nobody watched being made get exactly
        // one line that names them.
        let receipt = first(app, beginningWith: "missionAutoKeepReceipt.")
        XCTAssertTrue(receipt.waitForExistence(timeout: 30),
                      "Crumb kept things without leaving a receipt")
        XCTAssertTrue(receipt.label.contains("Kept"), "Receipt did not say what it did: \(receipt.label)")
        XCTAssertTrue(receipt.label.contains("$"), "Receipt did not state what it committed: \(receipt.label)")

        // And the deliverable moved, which is the point of delegating at all.
        XCTAssertTrue(keptHeader(app).waitForExistence(timeout: 15),
                      "The kit header never reflected Crumb's picks")

        // Collapsed by default; the ledger is one tap away.
        XCTAssertFalse(first(app, beginningWith: "missionAutoKeepRow.").exists,
                       "The receipt opened expanded — it should read as one line until asked")
        snap("02-receipt-collapsed")
        receipt.tap()
        XCTAssertTrue(first(app, beginningWith: "missionAutoKeepRow.").waitForExistence(timeout: 10),
                      "The receipt did not open into its ledger")
        snap("03-receipt-expanded")
    }

    @MainActor
    func testUndoSitsWithTheOrdinaryAnswersAndPutsThePicksBack() {
        let app = launch()
        turnOnAuto(app)
        XCTAssertTrue(first(app, beginningWith: "missionAutoKeepReceipt.").waitForExistence(timeout: 30))
        XCTAssertTrue(keptHeader(app).waitForExistence(timeout: 15))

        // Undo is a peer answer in the dock, not a gesture to discover.
        let undo = element(app, "missionResponseDock").descendants(matching: .any)
            .matching(identifier: "missionResponseOption.undo-auto").firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 15),
                      "Undo was not offered on the question right after the pass")
        // And it did not cost the ordinary answers their place: one option carrying a `detail`
        // folds the entire row into a "Choose a response" sheet.
        XCTAssertFalse(app.buttons["Choose a response"].exists,
                       "Adding Undo pushed the question's own answers behind a disclosure")
        snap("04-undo-alongside-the-answers")
        undo.tap()

        // The kit is empty again…
        let emptyHeader = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@",
                                  argumentArray: ["missionKitHeader", "nothing kept yet"]))
            .firstMatch
        XCTAssertTrue(emptyHeader.waitForExistence(timeout: 15),
                      "Undo did not empty the kit. Header: \(element(app, "missionKitHeader").label)")
        // …the offer is spent…
        XCTAssertFalse(undo.exists, "Undo stayed on offer after it had been taken")
        // …and the record of what happened stays, because it did happen.
        XCTAssertTrue(first(app, beginningWith: "missionAutoKeepReceipt.").exists,
                      "Undo erased the receipt instead of answering it")
        snap("05-after-undo")
    }
}
