import XCTest

/// Deterministic coverage for the mission-entry accessibility + direct-product-search work (#61),
/// using the seeded screenshot hooks (no live broker): onboarding controls must be queryable by
/// their OWN ids (not clobbered to the container id), and mission entry must advertise a direct
/// product search alongside the kit/space examples, all owned by the sole bottom composer.
final class MissionEntryAccessibilityUITests: XCTestCase {

    @MainActor
    func testOnboardingControlsAreQueryableByUniqueIdentifier() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "onboarding"   // empty store → first-run onboarding
        app.launch()

        // Skip / Next must resolve by their own ids — before the fix the root VStack's
        // "OnboardingScreen" identifier propagated onto every child, so these weren't queryable and
        // UI automation fell back to the visible "Skip" label.
        XCTAssertTrue(app.buttons["onboardingSkip"].waitForExistence(timeout: 20),
                      "#61: onboardingSkip is not queryable by id (OnboardingScreen clobbering)")
        XCTAssertTrue(app.buttons["onboardingNext"].exists,
                      "#61: onboardingNext is not queryable by id")

        // No actionable button should carry the container's identifier anymore.
        XCTAssertEqual(app.buttons.matching(identifier: "OnboardingScreen").count, 0,
                       "#61: actionable controls still report the container id 'OnboardingScreen'")
    }

    @MainActor
    func testMissionEntryUsesOneBottomComposerAndStagesExamples() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "composer"   // seeded profile → lands on Missions
        app.launch()

        let dock = app.descendants(matching: .any).matching(identifier: "missionResponseDock").firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout: 20), "Mission entry has no bottom composer")
        let field = app.descendants(matching: .any).matching(identifier: "missionResponseField").firstMatch
        XCTAssertTrue(field.exists, "New and active missions must share the same input field")
        XCTAssertEqual(app.textFields.count, 1, "Mission entry must expose exactly one editable field")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "composerField").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "planButton").firstMatch.exists)

        // A direct-product and a kit example remain discoverable, but tapping only stages text in
        // the composer; Send is still the one action that starts the mission.
        let jasmine = app.buttons["newMissionSuggestion.jasmine-tea"]
        XCTAssertTrue(jasmine.waitForExistence(timeout: 20),
                      "#61: mission entry shows no direct-product-search suggestion")
        XCTAssertTrue(app.buttons["newMissionSuggestion.pour-over"].exists,
                      "#61: kit/outfitting suggestion should remain alongside direct search")
        jasmine.tap()
        XCTAssertEqual(field.value as? String, "Find premium jasmine tea")
        XCTAssertTrue(app.buttons["missionResponseSend"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "MissionsScreen").firstMatch.exists,
                      "Staging an example must not submit it")
    }

    @MainActor
    func testSecondaryDestinationsLiveInOneHeaderMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "composer"
        app.launch()

        let more = app.descendants(matching: .any).matching(identifier: "moreMenu").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()

        for identifier in ["historyButton", "peopleButton", "tasteProfileButton", "siriButton"] {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: identifier).firstMatch.waitForExistence(timeout: 5),
                "More menu lost \(identifier)"
            )
        }
    }
}
