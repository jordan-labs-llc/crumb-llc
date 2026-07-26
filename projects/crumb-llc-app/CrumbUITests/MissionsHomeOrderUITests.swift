import XCTest

/// Reading-order and semantics coverage for the bottom-anchored Missions landing page.
///
/// Home rests its column on the dock, which inverts two things a sighted reader takes for granted:
/// the standing invitation is the LAST element rather than the first, and Continue rows run
/// oldest-first so the most recently touched mission sits nearest the composer. VoiceOver sweeps a
/// container geometrically, so reading order follows those frames — these tests pin that
/// relationship down, because a future re-order would silently change what a VoiceOver user hears
/// first without changing anything a screenshot would catch.
///
/// They also guard the semantics traded away when the visual "Continue" section header was removed:
/// each row must still announce itself as a continuation and state what is waiting inside.
final class MissionsHomeOrderUITests: XCTestCase {

    @MainActor
    private func launchSeededHome(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = mode
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "MissionsScreen").firstMatch
                .waitForExistence(timeout: 30),
            "Missions landing page never appeared"
        )
        return app
    }

    /// Every Continue row, in visual top-to-bottom order.
    @MainActor
    private func continueRows(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'continueThread.'"))
            .allElementsBoundByIndex
            .filter(\.exists)
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor
    func testGreetingIsReadAfterTheMissionsAndTheNewestMissionIsNearestTheDock() {
        let app = launchSeededHome("missions-many")

        let rows = continueRows(app)
        XCTAssertGreaterThan(rows.count, 1, "Seeded home should render several Continue rows")

        // The greeting is the last body element, so it sits BELOW every mission row. A bottom
        // anchor is only worth having if the invitation stays adjacent to the composer.
        let greeting = app.staticTexts["What are we shopping for?"]
        XCTAssertTrue(greeting.exists, "The standing invitation is missing from Home")
        for row in rows {
            XCTAssertLessThan(
                row.frame.minY, greeting.frame.minY,
                "Continue row '\(row.identifier)' is below the greeting; the greeting must stay last"
            )
        }

        // The dock owns the floor beneath the greeting.
        let dock = app.descendants(matching: .any).matching(identifier: "missionResponseDock").firstMatch
        XCTAssertTrue(dock.exists, "Home lost its response dock")
        XCTAssertLessThan(greeting.frame.minY, dock.frame.minY, "The greeting must sit above the dock")

        // Oldest-first: the seed stamps "Find premium jasmine tea" as the most recently updated
        // thread, so in a bottom-anchored column it must be the row closest to the composer.
        let last = rows[rows.count - 1]
        XCTAssertTrue(
            last.label.contains("Find premium jasmine tea"),
            "The most recently touched mission must be nearest the dock, found '\(last.label)'"
        )
    }

    @MainActor
    func testRowsStillAnnounceContinuationAndContentsWithoutASectionHeader() {
        let app = launchSeededHome("missions-many")

        // The visual "Continue" label was removed because it scrolls off a bottom-anchored list.
        // That is only acceptable while each row carries the word itself for VoiceOver.
        for row in continueRows(app) {
            XCTAssertTrue(
                row.label.hasPrefix("Continue "),
                "Row '\(row.identifier)' no longer announces itself as a continuation: '\(row.label)'"
            )
        }

        // Contents-derived status, not phase-derived. A settled deck that found nothing must never
        // be announced as having picks ready — that was the original defect.
        let labels = continueRows(app).map(\.label)
        XCTAssertFalse(
            labels.contains { $0.contains("Picks ready") },
            "A row announced the phase-derived 'Picks ready' string: \(labels)"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("kept") || $0.contains("to review") || $0.contains("Nothing found yet") },
            "No row announced a contents-derived status: \(labels)"
        )
    }

    @MainActor
    func testTeachingLineIsPresentOnColdStartAndRetiredOnceThereAreMissions() {
        let cold = launchSeededHome("composer")
        XCTAssertTrue(
            cold.staticTexts["I'll search the shops and bring back picks worth keeping."].exists,
            "A first-run visitor should still be told what the field does"
        )
        cold.terminate()

        let returning = launchSeededHome("missions-many")
        XCTAssertFalse(
            returning.staticTexts["I'll search the shops and bring back picks worth keeping."].exists,
            "The teaching line must retire once there are missions to show"
        )
        XCTAssertTrue(
            returning.staticTexts["What are we shopping for?"].exists,
            "Retiring the teaching line must not take the invitation with it"
        )
    }
}
