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
        var ucp: any UCPClient = LiveUCPClient(config: config) ?? MockUCPClient()
        #if DEBUG
        // Screenshots run on the mock catalog so the deck is the deterministic seed set
        // (no network, no live-curator variance) — which also exercises the synthesized
        // `ProductArt`, since seed products carry no real photo.
        if ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] != nil {
            ucp = MockUCPClient()
        }
        #endif
        // The Apple Foundation Models curator is the "real" voice; it self-degrades to the
        // rule-based engine (and reports why) when no model tier is usable, so it's safe to
        // always inject — mirroring LiveUCPClient ?? MockUCPClient for the catalog.
        // The taste extractor is the input twin: it parses a free-text self-description, and
        // self-degrades to `nil` (manual capture) when no model is available.
        let model = AppModel(
            ucp: ucp,
            curator: AppleFoundationCurator(),
            tasteStore: Self.makeTasteStore(),
            tasteExtractor: AppleFoundationTasteExtractor()
        )
        // Make the app model available to App Intents (`@Dependency`).
        AppDependencyManager.shared.add(dependency: model)
        _model = State(initialValue: model)
    }

    /// The persistent SwiftData store, or — under a `CRUMB_SCREENSHOT` launch environment
    /// (DEBUG only) — an in-memory store pre-seeded so the app skips onboarding and lands on
    /// a populated screen. `simctl` can't inject taps, so this is how deep screens are reached
    /// for headless screenshots; `RootView` reads the same env to deal a curate deck.

    /// The persistent SwiftData store for the taste profile, degrading to an in-memory store
    /// if the container can't be built (so a storage failure never blocks launch — the user
    /// just won't have their taste remembered across relaunches this session).
    private static func makeTasteStore() -> any TasteStore {
        #if DEBUG
        // A returning-user store for screenshots: a saved profile means no onboarding.
        if let mode = ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"], mode != "onboarding" {
            return InMemoryTasteStore(SeedData.defaultTasteProfile)
        }
        #endif
        return (try? SwiftDataTasteStore()) ?? InMemoryTasteStore()
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
