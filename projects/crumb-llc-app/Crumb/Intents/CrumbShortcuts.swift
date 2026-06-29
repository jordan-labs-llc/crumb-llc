import AppIntents

/// App Shortcuts that expose ``CurateKitIntent`` to Siri and the Shortcuts app.
struct CrumbShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // App Shortcut phrases can only embed `AppEntity`/`AppEnum` parameters, not a free-form
        // `String` — so the goal isn't spoken inline. Siri runs the intent on these phrases and
        // then asks "What do you want to shop for?" (the parameter's `requestValueDialog`),
        // capturing any open-ended goal and handing it to the same on-device planner.
        AppShortcut(
            intent: CurateKitIntent(),
            phrases: [
                "Ask \(.applicationName) to go shopping",
                "Curate a kit with \(.applicationName)",
            ],
            shortTitle: "Curate a kit",
            systemImageName: "sparkles"
        )
    }
}
