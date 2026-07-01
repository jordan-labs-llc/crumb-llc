import SwiftUI
import SwiftData
import AppIntents
import CrumbKit
import os

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
    private static let log = Logger(subsystem: "llc.crumb.Crumb", category: "Persistence")

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
        // The Apple Foundation Models mission planner decomposes a free-text goal into a plan;
        // like the curator it self-degrades to the deterministic `RuleBasedMissionPlanner` (and
        // reports why) when no model tier is usable, so it's safe to always inject.
        // One shared SwiftData container backs every persisted store. Building a separate
        // container per store makes them collide on the same `default.store` file (each creates
        // only its own entity's table), which silently breaks persistence — see `CrumbPersistence`.
        // A build failure degrades all four stores to in-memory (persistence off this session).
        let container = Self.makeSharedContainer()
        let model = AppModel(
            ucp: ucp,
            curator: AppleFoundationCurator(),
            tasteStore: Self.makeTasteStore(container: container),
            tasteExtractor: AppleFoundationTasteExtractor(),
            planner: AppleFoundationMissionPlanner(),
            refiner: AppleFoundationRefinementInterpreter(),
            // Fits the Curate refine chips to the mission (tea → Organic/Caffeine-free/Bolder);
            // self-degrades to the deterministic category taxonomy when no model tier is usable.
            chipSuggester: AppleFoundationRefineChipSuggester(),
            recapWriter: AppleFoundationRecapWriter(),
            // Drops clearly off-topic catalog results before curation; deterministic floor first,
            // then a best-effort on-device model pass that self-degrades to that floor.
            relevanceGate: AppleFoundationRelevanceGate(),
            // The model drives the search phase via Tools when a tier is up (searching each part,
            // reaching past the plan, widening a strong fit), degrading to the deterministic
            // fan-out + gate floor otherwise.
            orchestrator: AppleFoundationMissionOrchestrator(),
            recentsStore: Self.makeRecentsStore(container: container),
            historyStore: Self.makeHistoryStore(container: container),
            recipientStore: Self.makeRecipientStore(container: container)
        )
        // Make the app model available to App Intents (`@Dependency`).
        AppDependencyManager.shared.add(dependency: model)
        _model = State(initialValue: model)
    }

    /// The persistent SwiftData store, or — under a `CRUMB_SCREENSHOT` launch environment
    /// (DEBUG only) — an in-memory store pre-seeded so the app skips onboarding and lands on
    /// a populated screen. `simctl` can't inject taps, so this is how deep screens are reached
    /// for headless screenshots; `RootView` reads the same env to deal a curate deck.

    /// Builds the single shared SwiftData container, or `nil` (→ in-memory fallback) if it can't
    /// open. Under a `CRUMB_SCREENSHOT` launch the stores use seeded in-memory doubles instead, so
    /// no on-disk container is needed.
    private static func makeSharedContainer() -> ModelContainer? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] != nil { return nil }
        #endif
        do {
            return try CrumbPersistence.makeContainer()
        } catch {
            log.error("shared persistence unavailable — stores fall back to in-memory this session: \(error, privacy: .public)")
            return nil
        }
    }

    /// The taste-profile store over the shared `container`, degrading to an in-memory store if the
    /// container is absent (so a storage failure never blocks launch — the user just won't have
    /// their taste remembered across relaunches this session).
    private static func makeTasteStore(container: ModelContainer?) -> any TasteStore {
        #if DEBUG
        // A returning-user store for screenshots: a saved profile means no onboarding.
        if let mode = ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"], mode != "onboarding" {
            return InMemoryTasteStore(SeedData.defaultTasteProfile)
        }
        #endif
        guard let container else { return InMemoryTasteStore() }
        return SwiftDataTasteStore(container: container)
    }

    /// The SwiftData-backed recent-goals store, degrading to in-memory if the container can't be
    /// built. Under the composer screenshot env it's seeded so the "Recent" chips render.
    private static func makeRecentsStore(container: ModelContainer?) -> any RecentMissionsStore {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] == "composer" {
            return InMemoryRecentMissionsStore(["Make my desk feel calm", "Pack me for a rainy weekend hike"])
        }
        #endif
        guard let container else { return InMemoryRecentMissionsStore() }
        return SwiftDataRecentMissionsStore(container: container)
    }

    /// The SwiftData-backed history store, degrading to in-memory if the container can't be built
    /// (a storage failure never blocks launch — the user just won't have history this session).
    /// Under a `CRUMB_SCREENSHOT` launch env it's an in-memory store, seeded with deterministic
    /// entries for the `history` / `history-detail` modes and left empty otherwise (incl.
    /// `history-empty`, which captures the first-run timeline).
    private static func makeHistoryStore(container: ModelContainer?) -> any HistoryStore {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] {
            // `history-gift` seeds the gift-augmented set (a kit "for Mom") so the per-person filter
            // + "for <name>" tags render; the plain history modes keep the milestone-clean set of 5.
            let seed: [HistoryEntry]
            switch mode {
            case "history", "history-detail": seed = SeedData.historyEntries(now: Date())
            case "history-gift": seed = SeedData.giftHistoryEntries(now: Date())
            default: seed = []
            }
            return InMemoryHistoryStore(seed)
        }
        #endif
        guard let container else { return InMemoryHistoryStore() }
        return SwiftDataHistoryStore(container: container)
    }

    /// The SwiftData-backed recipient roster, degrading to in-memory if the container can't be
    /// built. Under the gift screenshot envs it's seeded with deterministic people (empty for
    /// `people-empty`, which captures the "no people yet" first-run state).
    private static func makeRecipientStore(container: ModelContainer?) -> any RecipientStore {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] {
            let needsPeople: Set<String> = ["people", "gift", "composer-gift", "history-gift"]
            return InMemoryRecipientStore(needsPeople.contains(mode) ? SeedData.recipients(now: Date()) : [])
        }
        #endif
        guard let container else { return InMemoryRecipientStore() }
        return SwiftDataRecipientStore(container: container)
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
