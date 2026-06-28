import SwiftUI
import AppIntents
import CrumbKit

/// Crumb — a task-driven personal-curator shopping agent.
///
/// SwiftUI `App` lifecycle. The `AppModel` is created with a UCP client and the
/// rule-based curator, injected into the environment, and registered as an **App Intents
/// dependency** so Siri / Shortcuts can route into the app (see `CurateKitIntent`).
///
/// The client is chosen from `Secrets.plist`: if `CRUMB_API_BASE_URL` is set, the app
/// talks to the live broker (`crumb-llc-api`); otherwise it runs entirely on
/// ``MockUCPClient`` (no network, no keys) — which is the default for the scaffold.
@main
struct CrumbApp: App {
    @State private var model: AppModel

    init() {
        let config = UCPConfig.load()
        let ucp: any UCPClient = LiveUCPClient(config: config) ?? MockUCPClient()
        let model = AppModel(ucp: ucp, curator: RuleBasedCurator())
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
