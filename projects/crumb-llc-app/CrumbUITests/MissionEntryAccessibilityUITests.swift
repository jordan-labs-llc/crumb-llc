import XCTest

/// Deterministic coverage for the mission-entry accessibility + direct-product-search work (#61),
/// using the seeded screenshot hooks (no live broker): onboarding controls must be queryable by
/// their OWN ids (not clobbered to the container id), and mission entry must advertise a direct
/// product search alongside the kit/space examples.
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
    func testMissionEntryOffersADirectProductSearchExample() {
        let app = XCUIApplication()
        app.launchEnvironment["CRUMB_SCREENSHOT"] = "composer"   // seeded profile → lands on Missions
        app.launch()

        // A direct-product example must be present so a first-run user learns finding one specific
        // product is a first-class use, not only kit/outfitting missions. The quick-start chips
        // carry the VoiceOver label "Plan: <prompt>".
        XCTAssertTrue(app.buttons["Plan: Find premium jasmine tea"].waitForExistence(timeout: 20),
                      "#61: mission entry shows no direct-product-search example")
        // The kit/space examples remain too — both modes are advertised.
        XCTAssertTrue(app.buttons["Plan: Set up my pour-over corner"].exists,
                      "#61: kit/outfitting examples should remain alongside the direct-product one")
    }
}
