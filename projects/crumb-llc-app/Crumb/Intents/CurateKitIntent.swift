import AppIntents

/// The "Hey Siri, ask Crumb to <any goal>" entry point. Opens the app and routes the spoken
/// goal through the same direct-mission chain the in-app composer uses: Crumb starts shopping
/// the goal right away — the agentic curator decides the catalog searches, no plan review.
struct CurateKitIntent: AppIntent {
    static let title: LocalizedStringResource = "Curate a kit"
    static let openAppWhenRun = true

    @Parameter(title: "Goal", requestValueDialog: "What do you want to shop for?")
    var goal: String

    /// The `AppModel` registered at launch (see `CrumbApp.init`).
    @Dependency var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.planMission(goal: goal)
        return .result()
    }
}
