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
        // "composer-examples" lands on an empty Missions page with NO recent goals, which is the only
        // state where the starter examples show: the dock now prefers your own recents, so under plain
        // "composer" these ids are `recent-*` instead. See the recents coverage below.
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "composer-examples"
        // The simulator defaults to an accessibility content size, at which the starter chips
        // deliberately collapse into a "Try an example" disclosure menu and these per-suggestion ids
        // do not exist. Pin a normal size so this test covers the chip path it is describing.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
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

    /// Your own recent goals replace the teaching examples once you have any — the recents store has
    /// been written after every mission since it was added, and until Home v2 no view read it.
    @MainActor
    func testRecentGoalsReplaceTheStarterExamples() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "composer"   // seeds two recent goals
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let firstRecent = app.buttons["newMissionSuggestion.recent-0"]
        XCTAssertTrue(firstRecent.waitForExistence(timeout: 20),
                      "The dock must offer your own recent goals when there are any")
        XCTAssertEqual(firstRecent.label, "Make my desk feel calm")

        // The hardcoded examples must not persist alongside them — that was the defect: a person on
        // their fortieth mission was still being offered "Premium jasmine tea".
        XCTAssertFalse(app.buttons["newMissionSuggestion.jasmine-tea"].exists,
                       "The starter examples must retire once there are recents")

        firstRecent.tap()
        let field = app.descendants(matching: .any).matching(identifier: "missionResponseField").firstMatch
        XCTAssertEqual(field.value as? String, "Make my desk feel calm",
                       "Tapping a recent must stage it without submitting")
    }

    @MainActor
    func testHistoryIsTopLevelAndTheRestLiveInOneHeaderMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "composer"
        app.launch()

        // History came out from behind the ellipsis: finished missions are a primary noun here and the
        // only route to re-shopping one. It must be reachable without opening the menu.
        let history = app.buttons["historyButton"]
        XCTAssertTrue(history.waitForExistence(timeout: 20),
                      "History must be a top-level header control")

        let more = app.descendants(matching: .any).matching(identifier: "moreMenu").firstMatch
        XCTAssertTrue(more.exists)
        XCTAssertLessThan(history.frame.minX, more.frame.minX,
                          "History must sit beside the menu, not inside it")
        more.tap()

        for identifier in ["peopleButton", "tasteProfileButton", "siriButton"] {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: identifier).firstMatch.waitForExistence(timeout: 5),
                "More menu lost \(identifier)"
            )
        }
    }
}
