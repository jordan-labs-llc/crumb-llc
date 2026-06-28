import AppIntents

/// The "Hey Siri, ask Crumb…" entry point. Opens the app, resolves the spoken phrase to a
/// seed mission, and routes to the Plan screen.
struct CurateKitIntent: AppIntent {
    static let title: LocalizedStringResource = "Curate a kit"
    static let openAppWhenRun = true

    @Parameter(title: "Mission")
    var mission: ShoppingTaskEntity

    /// The `AppModel` registered at launch (see `CrumbApp.init`).
    @Dependency var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.startMission(missionID: mission.id)
        return .result()
    }
}
