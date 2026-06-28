import AppIntents

/// App Shortcuts that expose ``CurateKitIntent`` to Siri and the Shortcuts app.
struct CrumbShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CurateKitIntent(),
            phrases: [
                "Ask \(.applicationName) to pack me for \(\.$mission)",
                "Have \(.applicationName) curate \(\.$mission)",
            ],
            shortTitle: "Curate a kit",
            systemImageName: "sparkles"
        )
    }
}
