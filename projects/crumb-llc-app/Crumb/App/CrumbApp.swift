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
/// talks to the live broker (`crumb-llc-api`). A normal launch without that configuration fails
/// closed through ``UnconfiguredUCPClient``; only explicit screenshot fixtures use mock catalog data.
@main
struct CrumbApp: App {
    private static let log = Logger(subsystem: "llc.crumb.Crumb", category: "Persistence")

    @State private var model: AppModel

    init() {
        let config = UCPConfig.load()
        var ucp: any UCPClient = LiveUCPClient(config: config) ?? UnconfiguredUCPClient()
        #if DEBUG
        // Screenshots run on the mock catalog so the deck is the deterministic seed set
        // (no network, no live-curator variance) — which also exercises the synthesized
        // `ProductArt`, since seed products carry no real photo.
        let env = ProcessInfo.processInfo.environment
        if env["CRUMB_SCREENSHOT"] != nil || env["CRUMB_UITEST_PERSISTENT_MOCK"] == "1" {
            ucp = MockUCPClient()
        }
        let usesDeterministicUITestSeams = env["CRUMB_UITEST_PERSISTENT_MOCK"] == "1"
        #else
        let usesDeterministicUITestSeams = false
        #endif
        let curator: any CuratorEngine = usesDeterministicUITestSeams
            ? RuleBasedCurator() : AppleFoundationCurator()
        let tasteExtractor: any TasteExtractor = usesDeterministicUITestSeams
            ? ManualTasteExtractor() : AppleFoundationTasteExtractor()
        // Missions are direct: the planner builds the deterministic mission shell (title, query,
        // kit expansion) in ~1ms — no upfront model decomposition, no approval turn. The one
        // model judgment left before the gather is the goal triage (isShoppable + isSingleItem),
        // one cheap guided call that self-degrades to the heuristics.
        let planner: any MissionPlanner = usesDeterministicUITestSeams
            ? RuleBasedMissionPlanner() : DirectMissionPlanner(triage: AppleFoundationGoalTriage())
        let refiner: any RefinementInterpreter = usesDeterministicUITestSeams
            ? RuleBasedRefinementInterpreter() : AppleFoundationRefinementInterpreter()
        let chipSuggester: any RefineChipSuggester = usesDeterministicUITestSeams
            ? RuleBasedRefineChipSuggester() : AppleFoundationRefineChipSuggester()
        let recapWriter: any RecapWriter = usesDeterministicUITestSeams
            ? RuleBasedRecapWriter() : AppleFoundationRecapWriter()
        let relevanceGate: any RelevanceGate = usesDeterministicUITestSeams
            ? RuleBasedRelevanceGate() : AppleFoundationRelevanceGate()
        let orchestrator: any MissionOrchestrator = usesDeterministicUITestSeams
            ? DeterministicMissionOrchestrator() : AppleFoundationMissionOrchestrator()
        // The Apple Foundation Models curator is the "real" voice; it self-degrades to the
        // rule-based engine (and reports why) when no model tier is usable, so it's safe to
        // always inject — mirroring the live/fail-closed catalog choice above.
        // The taste extractor is the input twin: it parses a free-text self-description, and
        // self-degrades to `nil` (manual capture) when no model is available.
        // One shared SwiftData container backs every persisted store. Building a separate
        // container per store makes them collide on the same `default.store` file (each creates
        // only its own entity's table), which silently breaks persistence — see `CrumbPersistence`.
        // A build failure degrades all four stores to in-memory (persistence off this session).
        let container = Self.makeSharedContainer()
        let threadStore = Self.makeThreadStore(container: container)
        let model = AppModel(
            ucp: ucp,
            curator: curator,
            tasteStore: Self.makeTasteStore(container: container),
            tasteExtractor: tasteExtractor,
            planner: planner,
            refiner: refiner,
            // Fits the Curate refine chips to the mission (tea → Organic/Caffeine-free/Bolder);
            // self-degrades to the deterministic category taxonomy when no model tier is usable.
            chipSuggester: chipSuggester,
            recapWriter: recapWriter,
            // Drops clearly off-topic catalog results before curation; deterministic floor first,
            // then a best-effort on-device model pass that self-degrades to that floor.
            relevanceGate: relevanceGate,
            // The model drives the search phase via Tools when a tier is up (searching each part,
            // reaching past the plan, widening a strong fit), degrading to the deterministic
            // fan-out + gate floor otherwise.
            orchestrator: orchestrator,
            recentsStore: Self.makeRecentsStore(container: container),
            historyStore: Self.makeHistoryStore(container: container),
            recipientStore: Self.makeRecipientStore(container: container),
            threadStore: threadStore
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
        if ProcessInfo.processInfo.environment["CRUMB_UITEST_PERSISTENT_MOCK"] == "1" {
            do {
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("MissionThreadUITests", isDirectory: true)
                if ProcessInfo.processInfo.environment["CRUMB_UITEST_RESET_STORE"] == "1" {
                    try? FileManager.default.removeItem(at: root)
                }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                return try CrumbPersistence.makeContainer(storeURL: root.appendingPathComponent("crumb-uitest.store"))
            } catch {
                log.error("isolated UI-test persistence unavailable: \(error, privacy: .public)")
                return nil
            }
        }
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
        let store = SwiftDataTasteStore(container: container)
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRUMB_UITEST_SEED_PROFILE"] == "1",
           store.loadProfile() == nil {
            store.saveProfile(SeedData.defaultTasteProfile)
        }
        #endif
        return store
    }

    /// The SwiftData-backed recent-goals store, degrading to in-memory if the container can't be
    /// built. Under the composer screenshot env it's seeded so the "Recent" chips render.
    private static func makeRecentsStore(container: ModelContainer?) -> any RecentMissionsStore {
        #if DEBUG
        // "composer" seeds recents, because the dock now offers your own recent goals. Every other
        // screenshot mode — including "composer-examples", which exists precisely to cover the
        // no-recents fallback — falls through to an empty store.
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

    /// Durable mission conversations use the same shared SwiftData container as every other store.
    /// Screenshot fixtures remain in memory; persistent mock UI tests intentionally use the real
    /// on-disk container so terminate/relaunch exercises restoration without a live broker.
    private static func makeThreadStore(container: ModelContainer?) -> any MissionThreadStore {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] {
            // The Missions landing page otherwise has no seeded route, so its populated states can
            // only be reached by running real missions. These fixtures let the bottom-anchored
            // layout be checked headlessly at one mission and at the continuation cap — the range
            // over which anchoring is most likely to degrade into a plain list.
            switch mode {
            case "missions-one": return InMemoryMissionThreadStore(seededThreads(count: 1))
            case "missions-many": return InMemoryMissionThreadStore(seededThreads(count: 8))
            case "missions-cap": return InMemoryMissionThreadStore(seededThreads(count: InMemoryMissionThreadStore.cap))
            // The hero renders whatever the most recent mission *has*, so the stalled hero is its own
            // composition — and no other fixture produces it, because `seededThreads` always makes the
            // newest thread a settled deck with kept items.
            case "missions-stalled": return InMemoryMissionThreadStore(seededStalledThreads())
            case "missions-inbox": return InMemoryMissionThreadStore(seededInboxThreads())
            default: return InMemoryMissionThreadStore()
            }
        }
        #endif
        guard let container else { return InMemoryMissionThreadStore() }
        return SwiftDataMissionThreadStore(container: container)
    }

    #if DEBUG
    /// A Home whose most recent mission is a stall carrying its own failure sentence, plus one thread
    /// still in flight. This is the composition where the hero has no deliverable to show and must
    /// state why it stopped instead.
    private static func seededStalledThreads() -> [MissionThread] {
        let now = Date()
        var stalled = MissionThread(
            goal: "Replace my worn-out running shoes",
            taste: SeedData.defaultTasteProfile,
            now: now.addingTimeInterval(-2 * 24 * 3600)
        )
        stalled.phase = .failed
        stalled.appendEvent(
            kind: .failure,
            text: "I searched six shops and found nothing under $90. The closest fit I trust is $124.",
            createdAt: now.addingTimeInterval(-2 * 24 * 3600)
        )
        stalled.updatedAt = now.addingTimeInterval(-2 * 24 * 3600)

        var working = MissionThread(
            goal: "Set up my pour-over corner",
            taste: SeedData.defaultTasteProfile,
            now: now.addingTimeInterval(-3 * 24 * 3600)
        )
        working.phase = .gathering
        working.updatedAt = now.addingTimeInterval(-3 * 24 * 3600)

        return [stalled, working]
    }

    /// The same composition as `missions-stalled`, but the stalled thread carries a real installed
    /// interaction — so its hero can be answered without opening the mission.
    ///
    /// This fixture is part of the feature, not decoration: no other fixture installs an interaction,
    /// so without it the answerable hero is unreachable headlessly and could only be checked by hand.
    /// The question and options are the ones `AppModel.installRetryQuestion` builds, so the fixture
    /// cannot drift into offering answers the real app never asks for.
    private static func seededInboxThreads() -> [MissionThread] {
        var threads = seededStalledThreads()
        guard var stalled = threads.first else { return threads }
        let asked = stalled.updatedAt
        // A retry-shaped thread in the real app always has a task and a plan — `runRetry` calls
        // `startCurating()` only when `selectedTask != nil`. Without one, answering "Retry" here would
        // resolve the question and then do nothing, and the fixture would be validating a state the app
        // cannot actually produce.
        stalled.task = SeedData.hike
        stalled.plan = SeedData.hike.plan.map { MissionPlanPart(label: $0, query: $0) }
        stalled.appendEvent(
            kind: .assistantMessage,
            text: "That turn didn’t finish. What next?",
            createdAt: asked
        )
        guard let promptID = stalled.timeline.last?.id else { return threads }
        let retry = MissionRetryDescriptor(
            kind: .gathering,
            input: "trail running shoes",
            taskRevision: stalled.revision,
            returnPhase: .failed
        )
        do {
            try stalled.installInteraction(
                promptEventID: promptID,
                subjectRevision: stalled.revision,
                kind: .retry,
                question: "That turn didn’t finish. What next?",
                options: [
                    MissionInteractionOption(id: "retry", label: "Retry"),
                    MissionInteractionOption(id: "cancel", label: "Cancel"),
                ],
                allowsFreeText: false,
                resolver: .retry(retry),
                createdAt: asked
            )
        } catch {
            // A fixture that silently loses its interaction would make the feature look broken rather
            // than the seed. Leave the un-answerable thread in place; the hero then renders its
            // navigation fallback, which is a valid state and an obvious signal something is off.
            log.error("inbox fixture could not install its interaction: \(error, privacy: .public)")
            return threads
        }
        stalled.updatedAt = asked
        threads[0] = stalled
        return threads
    }

    /// Deterministic unfinished threads for the Missions-landing screenshot routes. Distinct
    /// `updatedAt` values keep the store's recency sort meaningful, and the phases are spread so
    /// the Continue rows exercise more than one status string.
    private static func seededThreads(count: Int) -> [MissionThread] {
        let goals = [
            "Find premium jasmine tea",
            "Set up my pour-over corner",
            "Pack me for a rainy weekend hike",
            "Replace my worn-out running shoes",
            "Outfit a small home office",
            "Something for Maya's birthday",
            "Restock the coffee filters",
            "Warm layers for a cold-weather trip",
            "A better desk lamp",
            "Weeknight cast-iron cookware",
            "Rain shell that packs down small",
            "Start a small herb garden",
        ]
        let phases: [MissionThreadPhase] = [.deckReady, .gathering, .planReady, .failed]
        let now = Date()
        return (0..<min(count, goals.count)).map { index in
            let stamp = now.addingTimeInterval(TimeInterval(-600 * (index + 1)))
            var thread = MissionThread(
                goal: goals[index],
                taste: SeedData.defaultTasteProfile,
                now: stamp
            )
            thread.phase = phases[index % phases.count]
            // Settled threads get real contents so the Continue rows exercise all three of the
            // contents-derived summaries — kept items, unreviewed picks, and a gather that found
            // nothing — instead of every one of them rendering the empty case.
            if thread.phase == .deckReady {
                let products = Array(SeedData.hikeProducts.prefix(3))
                switch index % 3 {
                case 0:
                    thread.candidates = products
                    thread.baseCandidates = products
                    thread.kit = products.prefix(2).map { KitItem(product: $0) }
                    thread.remainingDeckIDs = products.dropFirst(2).map(\.id)
                case 1:
                    thread.candidates = products
                    thread.baseCandidates = products
                    thread.remainingDeckIDs = products.map(\.id)
                default:
                    break // the empty settled deck — the case that used to claim "Picks ready"
                }
            }
            thread.updatedAt = stamp
            return thread
        }
    }
    #endif

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
