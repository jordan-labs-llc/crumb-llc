import SwiftUI
import AppIntents
import CrumbKit

/// Crumb — a task-driven personal-curator shopping agent.
///
/// SwiftUI `App` lifecycle. The `AppModel` is created with the mock UCP client and the
/// rule-based curator (no network, no keys), injected into the environment, and
/// registered as an **App Intents dependency** so Siri / Shortcuts can route into the
/// app (see `CurateKitIntent`).
@main
struct CrumbApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        // Make the app model available to App Intents (`@Dependency`).
        AppDependencyManager.shared.add(dependency: model)
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 820)
        .windowResizability(.contentMinSize)
        #endif
    }
}
