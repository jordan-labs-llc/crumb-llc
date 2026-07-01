import Foundation
import Observation
import CrumbKit

/// Top-level navigation state for the Missions → Plan → Curate → Cart flow.
///
/// `onboarding` is the first-run entry: shown only when no ``TasteProfile`` has been
/// persisted yet, so a returning user never sees it.
enum Route: Hashable {
    case onboarding
    case missions
    case plan
    case curate
    case cart
    /// The timeline of past missions, reached from the app header.
    case history
    /// A read-only detail of one past mission's kit (the selected ``AppModel/selectedHistoryEntry``).
    case historyDetail
    /// The roster of people you shop for (the gift feature), reached from the app header.
    case people
}

/// One editable row of a generated plan: a human label plus the catalog query that finds it.
/// The composer's planner produces these; ``PlanView`` lets the user reword / add / remove them
/// before curating. Rewording a label re-derives its query (see ``AppModel/updatePart(_:label:)``).
struct PlanPart: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var query: String
}

extension ShoppingTask {
    /// An immutable copy with a new plan + queries, keeping the mission's identity (id, title,
    /// note, accent). Used to commit the user's plan edits back before curating.
    func rebuilt(plan: [String], searchQueries: [String]) -> ShoppingTask {
        ShoppingTask(
            id: id,
            title: title,
            subtitle: subtitle,
            plan: plan,
            curatorNote: curatorNote,
            accentHex: accentHex,
            candidateIDs: candidateIDs,
            searchQueries: searchQueries
        )
    }
}

/// The app's single source of truth.
///
/// `@Observable` (Observation framework) and `@MainActor`. Owns navigation `route`, the
/// selected mission, the user's `kit`, the `tasteProfile`, and the injected `UCPClient`
/// + `CuratorEngine` seams. Registered as an App Intents dependency at launch so Siri /
/// Shortcuts can drive navigation (see ``planMission(goal:)``).
@MainActor
@Observable
final class AppModel {

    // MARK: Navigation

    var route: Route = .missions
    private(set) var selectedTask: ShoppingTask?

    // MARK: Planning (the free-text composer → plan)

    /// `true` while the on-device planner is decomposing a typed goal into a mission. Drives the
    /// composer's "thinking" state.
    private(set) var isPlanning = false

    /// A short, friendly message when a typed goal isn't something Crumb can shop for (a
    /// question, nonsense, empty). `nil` when the last goal planned cleanly. Shown inline under
    /// the composer instead of routing into an empty plan.
    private(set) var planDecline: String?

    /// Which planner tier produced the current plan. Drives the honest "smart planning
    /// unavailable" note on the Plan screen (see ``plannerFallbackNote``).
    private(set) var plannerTier: PlannerTier?

    /// A short, user-facing note when Crumb wanted its AI planner but fell back to the simple
    /// deterministic plan (older device, Apple Intelligence off, offline). `nil` otherwise.
    var plannerFallbackNote: String? { plannerTier?.fallbackNote }

    /// The editable parts of the current plan — the curator's decomposition, which the user can
    /// reword / add to / trim on the Plan screen before curating. Committed back into the
    /// mission's queries when they tap "Curate my kit" (see ``beginCuration()``).
    private(set) var draftParts: [PlanPart] = []

    /// `true` when the plan has been edited (or freshly planned) since the last successful
    /// candidate load, so "Curate my kit" knows to re-run the search rather than reuse a
    /// stale deck.
    private var planDirty = false

    /// Recently typed goals, most-recent-first, surfaced as quick-tap chips in the composer.
    private(set) var recentGoals: [String] = []

    // MARK: Domain state

    private(set) var kit: [KitItem] = []

    // MARK: History (the persisted record of past missions)

    /// All saved missions, most-recent-first — the timeline's data. Refreshed from the store after
    /// every write so the History screen reflects the latest kit, outcome, or deletion.
    private(set) var historyEntries: [HistoryEntry] = []

    /// The entry the read-only History detail is showing (set by ``openHistoryDetail(_:)``).
    private(set) var selectedHistoryEntry: HistoryEntry?

    /// When set, the re-shop sheet for a past entry is presented (the snapshot's per-item buy links,
    /// honest about gone links — the History twin of ``handoff``).
    var reshopEntry: HistoryEntry?

    /// The id of the entry for the *current* shopping session, or `nil` before the kit first reaches
    /// the cart this session. Stable per `enterPlan`, so re-reaching the cart updates the same entry
    /// (and a real checkout handoff flips that entry's outcome). A new mission starts a fresh id.
    private var currentHistoryEntryID: String?

    /// The user's *original* free-text goal for this session, so a saved entry stores the real goal
    /// (not `ShoppingTask.title`, which the planner title-cases and length-caps) and "Plan this
    /// again" re-plans exactly what they typed. `nil` for the seed-mission path, where the task's
    /// own title is the faithful goal.
    private var currentMissionGoal: String?

    /// The current per-recipient History filter (the chip row at the top of the timeline). `.all` by
    /// default; `.yourself` / `.person(id)` narrow the timeline to one person's kits.
    var historyRecipientFilter: HistoryRecipientFilter = .all

    /// The history entries passing the active recipient filter — what the timeline actually renders.
    var filteredHistoryEntries: [HistoryEntry] {
        HistoryFacets.apply(historyRecipientFilter, to: historyEntries)
    }

    /// The filter chips a history warrants (All · You · each person with a saved gift kit), tinted.
    var historyFacets: [HistoryRecipientFacet] {
        HistoryFacets.facets(historyEntries, ownerAccentHex: Self.ownerAccentHex)
    }

    /// The aggregate "since you started" stat line for the History header — over the **filtered**
    /// set, so "everything for Mom" gets its own honest totals.
    var historyStats: HistoryStats { HistoryStats(entries: filteredHistoryEntries) }

    /// The user's taste — the single persisted piece of domain state. Read-only to views;
    /// all edits flow through ``updateTaste(_:)`` so every change is persisted *and* re-curates
    /// the live deck.
    private(set) var tasteProfile: TasteProfile

    // MARK: Recipients (the people you shop *for* — the gift feature)

    /// The saved roster of people you shop for, most-recently-added-first. Refreshed from the store
    /// after every write. "Yourself" is **not** here — it's the owner ``tasteProfile`` (the absence
    /// of a recipient).
    private(set) var recipients: [Recipient] = []

    /// The composer's "Who's this for?" selection — the person a *new* mission will be for, or `nil`
    /// for Yourself. Opt-in per mission and reset to Yourself whenever the composer is returned to,
    /// so a new mission always defaults to Yourself (zero regression to today's flow).
    var composerRecipient: Recipient?

    /// The **active** mission's recipient (`nil` = Yourself). Set when a mission is started for
    /// someone and carried through plan → curate → refine → recap; reset on the next `enterPlan`.
    /// This is the switch behind ``activeTaste``: the whole curation pipeline reads *their* taste.
    private(set) var activeRecipient: Recipient?

    /// The taste the *current mission* curates through: the active recipient's when shopping for
    /// someone, else the owner's. **Every** seam call that used to pass `tasteProfile` now passes
    /// this, so "become their shopper" is a single source of truth.
    var activeTaste: TasteProfile { activeRecipient?.taste ?? tasteProfile }

    /// The lean recipient snapshot threaded into the curator + recap as gift context (and stamped
    /// onto the saved history entry). `nil` for an owner mission.
    var activeRecipientRef: RecipientRef? { activeRecipient.map(RecipientRef.init) }

    /// The owner's accent for the History "You" facet chip (the app's default pine).
    static let ownerAccentHex: UInt32 = 0x1C4B43

    /// A small, on-brand earthy palette assigned to new people by add-order, so each person gets a
    /// distinct tint for their cards/chips (like a mission's accent).
    static let recipientAccents: [UInt32] = [
        0x9A6A4F, 0x4F6D7A, 0x7A5C7E, 0x5E7A52, 0xB07D48, 0x55708A, 0x8A6D3B, 0x6E5774,
    ]

    /// The opt-in "make this part of <whose> taste" copy on the refinement bar — addressed to the
    /// active recipient during a gift mission, else to the owner.
    var saveToTasteLabel: String {
        if let name = activeRecipient?.name { return "Make this part of \(name)'s taste" }
        return "Make this part of your taste"
    }

    /// `true` while a profile edit is re-ranking and re-voicing the on-screen deck. Drives the
    /// Curate screen's "re-reading your taste" shimmer so the personalization is *felt*.
    private(set) var isRecurating = false

    // MARK: Conversational refinement (talk back to the curator)

    /// The running per-mission refinement conversation, oldest-first ("make it cheaper", then
    /// "but keep the kettle"). Fed to the interpreter every time so refinements compose.
    /// **Ephemeral**: cleared on `enterPlan` (a new mission) and never persisted across launches.
    private(set) var refinementTurns: [String] = []

    /// `true` while a refinement is reworking the on-screen deck. Drives the Curate screen's
    /// "Reworking the deck…" shimmer (the sibling of `isRecurating`).
    private(set) var isReworking = false

    /// Which interpreter tier read the latest refinement. Drives the honest "smart refining
    /// unavailable" note on the Curate screen (see ``refinementFallbackNote``).
    private(set) var refinementTier: RefinementTier?

    /// A short, user-facing note when Crumb wanted its AI interpreter but fell back to the
    /// deterministic refinement read. `nil` otherwise.
    var refinementFallbackNote: String? { refinementTier?.fallbackNote }

    /// `true` once at least one refinement has been applied this mission (and not yet saved or
    /// reset), so the Curate screen can offer the quiet "make this part of your taste" affordance.
    private(set) var canSaveRefinementToTaste = false

    /// The directives applied this mission, kept so "save to taste" can deterministically fold
    /// them into the profile when no model is available to re-read the text (sim/CI).
    private var refinementDirectives: [RefinementDirective] = []

    /// The deck as first dealt for this mission, before any refinement — the snapshot
    /// ``resetRefinements()`` restores so Reset truly undoes the conversation.
    private var baseCandidates: [Product] = []

    /// Ranked candidate products for the selected mission.
    private(set) var candidates: [Product] = []
    /// The remaining swipe deck (candidates not yet decided on).
    private(set) var deck: [Product] = []

    /// Where the Plan screen's candidate load currently stands.
    enum LoadState: Equatable {
        case idle
        case loading   // "scanning shops…"
        case loaded    // results in `candidates` (possibly empty == "no matches")
        case failed    // every query errored (broker down / offline) — retryable
    }

    private(set) var loadState: LoadState = .idle

    /// Which curator voice produced the current deck. Drives the honest "AI curator
    /// unavailable" note on the Curate screen (see ``curatorFallbackNote``).
    private(set) var curatorTier: CuratorTier?

    /// A short, user-facing note when Crumb wanted its AI curator but had to fall back to
    /// the deterministic voice (older device, Apple Intelligence off, quota spent, offline).
    /// `nil` when the AI curator ran, or when rule-based is the configured default.
    var curatorFallbackNote: String? { curatorTier?.fallbackNote }

    /// `true` while Crumb is "scanning shops" on the Plan screen.
    var isScanning: Bool { loadState == .loading }
    /// `true` when the load failed outright (distinct from a successful empty result).
    var loadFailed: Bool { loadState == .failed }

    // MARK: Overlay state

    var isShowingTasteProfile = false
    /// When set, the per-shop checkout handoff sheet is presented.
    var handoff: Handoff?

    /// A per-shop checkout handoff. `url` is the resolved UCP `continue_url` (or the
    /// merchant storefront fallback); `nil` means no handoff target exists for this shop —
    /// the sheet surfaces that honestly instead of the button silently doing nothing.
    struct Handoff: Identifiable, Hashable {
        let shop: Shop
        let url: URL?
        let items: [KitItem]
        var id: String { shop.id }
    }

    // MARK: Dependencies (seams)

    let ucp: any UCPClient
    let curator: any CuratorEngine
    let tasteExtractor: any TasteExtractor
    let planner: any MissionPlanner
    let refiner: any RefinementInterpreter
    let recapWriter: any RecapWriter
    /// Drops clearly off-topic catalog results *before* the curator ranks/voices them, so a stray
    /// live result never reaches the deck with a confident rationale. Defaults to the deterministic
    /// floor (no model, mock-safe) so existing tests and the scaffold need nothing.
    let relevanceGate: any RelevanceGate
    /// Gathers the mission's candidate pool (the search + relevance phase). Defaults to the
    /// deterministic floor (the exact fan-out + gate the pipeline ran inline, no model, mock-safe);
    /// the app wires ``AppleFoundationMissionOrchestrator``, which lets the model *drive* the search
    /// via Tools when one is up and degrades to this floor otherwise.
    let orchestrator: any MissionOrchestrator
    private let tasteStore: any TasteStore
    private let recentsStore: any RecentMissionsStore
    private let historyStore: any HistoryStore
    private let recipientStore: any RecipientStore
    /// Injected wall-clock — used only at save time for an entry's `createdAt` (and the session
    /// entry id). A closure so tests can pin time and keep timeline grouping deterministic; pure
    /// logic never calls `Date()` directly (see [[ios-sim-available-xcode27]] build notes).
    private let clock: () -> Date

    /// Builds the app model, restoring the persisted ``TasteProfile`` if one exists.
    ///
    /// The presence of a stored profile is also the first-run signal: with none, the app opens
    /// on ``Route/onboarding`` (and falls back to the seed profile as the editable starting
    /// point); with one, it opens straight on Missions. `tasteStore` and `tasteExtractor`
    /// default to the keyless in-memory / manual doubles so existing tests and the mock
    /// scaffold need no model or disk.
    init(
        ucp: any UCPClient,
        curator: any CuratorEngine,
        tasteStore: any TasteStore = InMemoryTasteStore(),
        tasteExtractor: any TasteExtractor = ManualTasteExtractor(),
        planner: any MissionPlanner = RuleBasedMissionPlanner(),
        refiner: any RefinementInterpreter = RuleBasedRefinementInterpreter(),
        recapWriter: any RecapWriter = RuleBasedRecapWriter(),
        relevanceGate: any RelevanceGate = RuleBasedRelevanceGate(),
        orchestrator: any MissionOrchestrator = DeterministicMissionOrchestrator(),
        recentsStore: any RecentMissionsStore = InMemoryRecentMissionsStore(),
        historyStore: any HistoryStore = InMemoryHistoryStore(),
        recipientStore: any RecipientStore = InMemoryRecipientStore(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.ucp = ucp
        self.curator = curator
        self.tasteStore = tasteStore
        self.tasteExtractor = tasteExtractor
        self.planner = planner
        self.refiner = refiner
        self.recapWriter = recapWriter
        self.relevanceGate = relevanceGate
        self.orchestrator = orchestrator
        self.recentsStore = recentsStore
        self.historyStore = historyStore
        self.recipientStore = recipientStore
        self.clock = clock

        let stored = tasteStore.loadProfile()
        self.tasteProfile = stored ?? SeedData.defaultTasteProfile
        self.route = stored == nil ? .onboarding : .missions
        self.recentGoals = recentsStore.loadRecents()
        self.historyEntries = historyStore.loadEntries()
        self.recipients = recipientStore.loadRecipients()
    }

    // MARK: Derived

    var missions: [ShoppingTask] { SeedData.missions }

    var currentCart: Cart { Cart(items: kit) }

    var accentHex: UInt32 { selectedTask?.accentHex ?? 0x1C4B43 }

    func isInKit(_ product: Product) -> Bool {
        kit.contains { $0.product.id == product.id }
    }

    // MARK: Navigation actions

    /// Selects a pre-built mission and routes to Plan, kicking off the "scanning shops" load
    /// immediately. The seed-mission path used by tests and the screenshot hooks; the live
    /// composer path goes through ``runPlan(goal:)`` → ``enterPlan(with:)`` instead, which
    /// defers the search until the user has edited the plan and tapped "Curate my kit".
    func select(_ task: ShoppingTask) {
        enterPlan(with: task)
        loadState = .loading
        planDirty = false
        Task { await loadCandidates(for: task) }
    }

    /// Re-runs the candidate load for the current mission (the Plan screen's "Retry").
    func retryLoad() {
        guard selectedTask != nil else { return }
        startCurating()
    }

    // MARK: Planning (free-text composer)

    /// Plans a typed goal in the background (the composer's "Plan it"). Fire-and-forget wrapper
    /// over ``runPlan(goal:)`` so the button stays synchronous; the async core is what tests
    /// drive deterministically.
    func planMission(goal: String, for recipient: Recipient? = nil) {
        Task { await runPlan(goal: goal, for: recipient) }
    }

    /// Decomposes `goal` via the injected ``MissionPlanner`` and either routes into an editable
    /// Plan (shoppable) or surfaces a friendly decline under the composer (not shoppable). A
    /// shoppable goal is also recorded in recents. Internal (not private) so tests can await it
    /// rather than racing the fire-and-forget `Task`.
    func runPlan(goal: String, for recipient: Recipient? = nil) async {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPlanning = true
        planDecline = nil
        defer { isPlanning = false }

        // The plan itself is curated to the recipient's taste when this is a gift mission, so the
        // parts the user edits already read as theirs.
        let profile = recipient?.taste ?? tasteProfile
        let planned = await CrumbTrace.measure("plan", summarize: {
            "goalChars=\(trimmed.count) shoppable=\($0.task != nil) parts=\($0.task?.plan.count ?? 0) tier=\($0.tier.traceLabel)"
        }) {
            await planner.plan(goal: trimmed, profile: profile)
        }
        if let task = planned.task {
            recentsStore.addRecent(trimmed)
            recentGoals = recentsStore.loadRecents()
            plannerTier = planned.tier
            enterPlan(with: task, recipient: recipient)
            currentMissionGoal = trimmed   // the real goal, for a faithful record + re-plan
        } else {
            planDecline = planned.decline
                ?? "I'm a shopping curator — hand me something to shop for."
        }
    }

    /// Sets up the Plan screen for `task`: seeds the editable parts, resets the deck, and routes
    /// to Plan **without** searching yet (the search runs on "Curate my kit", after edits).
    func enterPlan(with task: ShoppingTask, recipient: Recipient? = nil) {
        selectedTask = task
        // Who this mission is for — `nil` = Yourself. Set here (not in the composer) so every entry
        // point (live composer, seed `select`, screenshot, planAgain) resolves the recipient the
        // same way and the curation pipeline reads `activeTaste` from this single switch.
        activeRecipient = recipient
        draftParts = Self.draftParts(from: task)
        kit.removeAll()
        candidates = []
        deck = []
        curatorTier = nil
        clearRefinement()
        // A new shopping session — the next cart-reach starts a fresh history entry, not an update
        // to the previous mission's one. The seed-mission path leaves `currentMissionGoal` nil so
        // the task's own title stands in as the goal; `runPlan` sets the real typed goal after.
        currentHistoryEntryID = nil
        currentMissionGoal = nil
        loadState = .idle
        planDirty = true
        route = .plan
    }

    /// Resets the ephemeral refinement conversation and its derived state — called whenever a new
    /// mission is entered (so refinements never leak across missions) and when a fresh deck is
    /// dealt. Does not touch the persisted ``TasteProfile``.
    private func clearRefinement() {
        refinementTurns = []
        refinementTier = nil
        refinementDirectives = []
        canSaveRefinementToTaste = false
        isReworking = false
    }

    /// Builds editable parts from a task, pairing each plan label with its query by index and
    /// deriving a query from the label when the arrays don't line up (e.g. seed missions, whose
    /// labels and queries aren't 1:1).
    private static func draftParts(from task: ShoppingTask) -> [PlanPart] {
        task.plan.enumerated().map { index, label in
            let raw = index < task.searchQueries.count ? task.searchQueries[index] : label
            return PlanPart(label: label, query: RuleBasedMissionPlanner.clean(query: raw))
        }
    }

    // MARK: Plan editing

    /// Adds a new part to the draft plan (capped at ``RuleBasedMissionPlanner/maxParts``). Its
    /// query is derived from the label.
    func addPart(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, draftParts.count < RuleBasedMissionPlanner.maxParts else { return }
        draftParts.append(PlanPart(label: trimmed, query: RuleBasedMissionPlanner.clean(query: trimmed)))
        planDirty = true
    }

    /// Removes a part from the draft plan.
    func removePart(_ part: PlanPart) {
        draftParts.removeAll { $0.id == part.id }
        planDirty = true
    }

    /// Rewords a part's label and re-derives its query, so a reworded part re-runs against a
    /// query that matches the new wording when the user next curates.
    func updatePart(_ part: PlanPart, label: String) {
        guard let index = draftParts.firstIndex(where: { $0.id == part.id }) else { return }
        draftParts[index].label = label
        draftParts[index].query = RuleBasedMissionPlanner.clean(query: label)
        planDirty = true
    }

    /// Advances from Plan to the swipe deck, committing any plan edits and (re-)running the
    /// catalog search first. Fire-and-forget wrapper over ``beginCuration()``.
    func startCurating() {
        Task { await beginCuration() }
    }

    /// Commits the edited plan into the mission's queries and loads candidates, then advances
    /// to Curate on success (staying on Plan to show the scanning / failed state otherwise). A
    /// clean, already-loaded plan (e.g. returning from Curate without edits) skips the reload.
    func beginCuration() async {
        guard let base = selectedTask else { return }
        if !planDirty, loadState == .loaded, !candidates.isEmpty {
            route = .curate
            return
        }
        let queries = draftParts.map(\.query).filter { !$0.isEmpty }
        guard !queries.isEmpty else { return }   // nothing searchable — CTA is disabled anyway
        let task = base.rebuilt(plan: draftParts.map(\.label), searchQueries: queries)
        selectedTask = task
        planDirty = false
        await loadCandidates(for: task)
        if loadState == .loaded { route = .curate }
    }

    #if DEBUG
    /// Screenshot/UITest hook: deterministically deal a mission's curated deck and land on
    /// Curate, bypassing onboarding and the Plan step. `simctl` can't tap, so headless deep
    /// screens are reached this way (driven by `CRUMB_SCREENSHOT` in `CrumbApp`/`RootView`).
    func presentCurateForScreenshot(missionID: String) async {
        let task = missions.first { $0.id == missionID } ?? SeedData.hike
        selectedTask = task
        kit.removeAll()
        candidates = []
        deck = []
        curatorTier = nil
        clearRefinement()
        await loadCandidates(for: task)
        route = .curate
    }

    /// Screenshot hook: deal a deck then accept every card, landing on Curate's "that's a
    /// kit" empty state so its art can be captured headlessly.
    func presentFullKitForScreenshot(missionID: String) async {
        await presentCurateForScreenshot(missionID: missionID)
        for product in deck { accept(product) }
    }

    /// Screenshot hook: land on the editable Plan screen for a seed mission (which carries a
    /// rich multi-part plan), so the plan-editor surface can be captured headlessly. The live
    /// composer can't be typed into via `simctl`; this stands in for a freshly planned mission.
    func presentPlanForScreenshot(missionID: String) {
        let task = missions.first { $0.id == missionID } ?? SeedData.hike
        enterPlan(with: task)
    }

    /// Screenshot hook: deal a mission's deck then run a canned `refinement` through the (sim's
    /// rule-based) interpreter so the reworked deck, the "Reworking…" state, and the refinement
    /// bar all render headlessly — `simctl` can inject neither taps nor keystrokes.
    func presentRefinedDeckForScreenshot(missionID: String, refinement: String) async {
        await presentCurateForScreenshot(missionID: missionID)
        await applyRefinement(text: refinement)
    }

    /// Screenshot hook: land on the History timeline (the store is seeded with deterministic
    /// entries — or left empty for the first-run state — in `CrumbApp`).
    func presentHistoryForScreenshot() {
        route = .history
    }

    /// Screenshot hook: open the read-only detail of the most recent seeded entry, so the kit,
    /// recap, and re-shop / plan-again actions render headlessly.
    func presentHistoryDetailForScreenshot() {
        if let first = historyEntries.first {
            openHistoryDetail(first)
        } else {
            route = .history
        }
    }

    /// Screenshot hook: land on the People roster (the store is seeded with deterministic people —
    /// or left empty for the "no people yet" state — in `CrumbApp`).
    func presentPeopleForScreenshot() {
        route = .people
    }

    /// Screenshot hook: land on Missions with a seeded recipient chosen in the composer, so the
    /// "Who's this for?" picker renders with someone selected (`simctl` can't tap a chip).
    func presentComposerGiftForScreenshot() {
        composerRecipient = recipients.first
        route = .missions
    }

    /// Screenshot hook: deal a **gift** curate deck — seeds `activeRecipient` (so curation reads the
    /// recipient's taste and the rule-based floor renders gift-framed voice) then deals the deck via
    /// the same proven path as ``presentCurateForScreenshot(missionID:)`` (which lands directly on
    /// Curate, never routing through the Plan step).
    func presentGiftCurateForScreenshot(missionID: String) async {
        activeRecipient = recipients.first
        await presentCurateForScreenshot(missionID: missionID)
    }

    /// Screenshot hook: land on History filtered to the first seeded person, so the "for <name>"
    /// tags + the per-person filter chip row render headlessly.
    func presentGiftHistoryForScreenshot() {
        if let id = historyEntries.compactMap({ $0.recipient?.id }).first {
            historyRecipientFilter = .person(id)
        }
        route = .history
    }
    #endif

    func openCart() {
        route = .cart
        // Reaching the cart with a kit is the save trigger: record (or update) this session's
        // history entry. Fire-and-forget so navigation stays instant; the recap is written async.
        recordKitToHistory()
    }

    func goToMissions() {
        // Returning to the composer resets the picker to Yourself — gifting is opt-in per mission.
        composerRecipient = nil
        route = .missions
    }

    // MARK: History — writing the record

    /// Fire-and-forget wrapper over ``recordCurrentKit()`` (the recap write is async). Internal so
    /// tests can await the async core deterministically rather than racing the `Task`.
    func recordKitToHistory() {
        Task { await recordCurrentKit() }
    }

    /// Snapshots the current kit into a ``HistoryEntry`` and saves it — the heart of the History
    /// feature. Writes only when there's a mission and at least one kept item (an abandoned plan
    /// with nothing kept is never recorded). Within one session it **upserts** the same entry
    /// (preserving its `createdAt` and any `handedOff` already earned), so back→edit→cart
    /// round-trips don't litter history with near-duplicates; a new mission (`enterPlan`) starts a
    /// fresh entry.
    ///
    /// Two correctness rules shape the order of work here:
    /// - **The row is saved synchronously *before* the slow on-device recap call**, seeded with the
    ///   deterministic floor recap and its id assigned, so the entry is complete and findable the
    ///   instant the user can act on it. Otherwise ``recordHandoffFollowed()`` could race the
    ///   awaited recap and silently no-op (the id wouldn't be set yet) on a real device.
    /// - **The recap is only (re)generated when the kept set actually changes.** A plain cart
    ///   re-reach reuses the stored recap, so a non-deterministic model can't make a kit's saved
    ///   title/line wobble between visits.
    func recordCurrentKit() async {
        guard let task = selectedTask, !kit.isEmpty else { return }

        let items = kit.map(HistoryItem.init)
        let goal = currentMissionGoal ?? task.title

        // Reuse this session's id/createdAt/outcome on a re-reach; otherwise mint a new entry.
        let existing = currentHistoryEntryID.flatMap { id in historyEntries.first { $0.id == id } }
        let id: String
        let createdAt: Date
        let handedOff: Bool
        if let existing {
            id = existing.id
            createdAt = existing.createdAt
            handedOff = existing.handedOff
        } else {
            let now = clock()
            id = "\(task.id)-\(Int(now.timeIntervalSinceReferenceDate))"
            createdAt = now
            handedOff = false
            currentHistoryEntryID = id
        }

        let facts = items.map(RecapFact.init)
        let keptChanged = existing.map { Set($0.items.map(\.productID)) != Set(items.map(\.productID)) } ?? true

        // Snapshot who this kit was for (a gift) — `nil` for an owner kit. Captured at save time so
        // the entry stays a faithful receipt even if the person is later edited or deleted.
        let recipientRef = activeRecipientRef

        func makeEntry(tag: String, line: String, handedOff: Bool) -> HistoryEntry {
            HistoryEntry(
                id: id, goal: goal, title: task.title, subtitle: task.subtitle,
                plan: task.plan, searchQueries: task.searchQueries, curatorNote: task.curatorNote,
                accentHex: task.accentHex, recapTag: tag, recapLine: line, items: items,
                recipient: recipientRef, handedOff: handedOff, createdAt: createdAt
            )
        }

        // Seed the recap: reuse the existing one when the kept set is unchanged (no jitter on a
        // plain re-reach); otherwise compute the deterministic floor *synchronously* so the saved
        // row is already complete before we await the on-device upgrade below.
        let seedTag: String
        let seedLine: String
        if let existing, !keptChanged {
            seedTag = existing.recapTag
            seedLine = existing.recapLine
        } else {
            let floor = RuleBasedRecapWriter.recap(
                goal: goal, plan: task.plan, items: facts, profile: activeTaste,
                recipient: recipientRef, reason: nil
            )
            seedTag = floor.tag
            seedLine = floor.line
        }
        historyStore.save(makeEntry(tag: seedTag, line: seedLine, handedOff: handedOff))
        historyEntries = historyStore.loadEntries()

        // Upgrade with the on-device writer only when we (re)generated a recap. Best-effort and
        // race-safe: re-read the latest outcome (a handoff may have landed during the await) and
        // bail if the session moved on.
        guard keptChanged else { return }
        let written = await recapWriter.writeRecap(
            goal: goal, plan: task.plan, items: facts, profile: activeTaste, recipient: recipientRef
        )
        guard currentHistoryEntryID == id, let latest = historyEntries.first(where: { $0.id == id }) else { return }
        historyStore.save(makeEntry(tag: written.tag, line: written.line, handedOff: latest.handedOff))
        historyEntries = historyStore.loadEntries()
    }

    /// Flips this session's entry to "handed off" — called when the user actually opens a real
    /// checkout link from the handoff sheet (the honest outcome signal; a no-link handoff doesn't
    /// count). No-op if the kit never reached the cart this session.
    func recordHandoffFollowed() {
        guard let id = currentHistoryEntryID else { return }
        historyStore.setHandedOff(id, true)
        historyEntries = historyStore.loadEntries()
    }

    // MARK: History — reading & managing

    /// Opens the History timeline (the header affordance).
    func openHistory() {
        route = .history
    }

    /// Opens the read-only detail for a past entry.
    func openHistoryDetail(_ entry: HistoryEntry) {
        selectedHistoryEntry = entry
        route = .historyDetail
    }

    /// Deletes a single entry (swipe / menu), refreshing the timeline and stepping back out of a
    /// detail that was showing it.
    func deleteHistoryEntry(_ entry: HistoryEntry) {
        historyStore.delete(id: entry.id)
        historyEntries = historyStore.loadEntries()
        if selectedHistoryEntry?.id == entry.id {
            selectedHistoryEntry = nil
            if route == .historyDetail { route = .history }
        }
    }

    /// Clears the entire history ("Clear history"), returning to the now-empty timeline.
    func clearHistory() {
        historyStore.clear()
        historyEntries = []
        historyRecipientFilter = .all
        selectedHistoryEntry = nil
        if route == .historyDetail { route = .history }
    }

    /// Presents the re-shop sheet for a past entry (its snapshot's per-item buy links).
    func beginReshop(_ entry: HistoryEntry) {
        reshopEntry = entry
    }

    /// Routes a past entry's goal back through the planner into a fresh, editable plan — "Plan this
    /// again". A new session, so building a kit from it becomes a new history entry.
    func planAgain(_ entry: HistoryEntry) {
        reshopEntry = nil
        selectedHistoryEntry = nil
        // Re-plan for the same person when the kit was a gift and they're still in the roster;
        // otherwise (owner kit, or a since-deleted person) re-plan for Yourself.
        let recipient = entry.recipient.flatMap { ref in recipients.first { $0.id == ref.id } }
        planMission(goal: entry.goal, for: recipient)
    }

    /// Steps one level back in the flow.
    func back() {
        switch route {
        case .onboarding, .missions: break  // roots — nothing to step back to
        case .plan: route = .missions
        case .curate: route = .plan
        case .cart: route = .curate
        case .history: route = .missions
        case .historyDetail: route = .history
        case .people: route = .missions
        }
    }

    // MARK: Taste capture

    /// Finishes first-run onboarding with the profile the user built, persists it, and routes
    /// into the app. (No deck exists yet, so this never triggers a re-curate.)
    func completeOnboarding(with profile: TasteProfile) {
        updateTaste(profile)
        route = .missions
    }

    /// Skips onboarding: keep the seed profile but persist it, so the store now has a value and
    /// the user lands on the standard defaults instead of being asked again next launch.
    func skipOnboarding() {
        tasteStore.saveProfile(tasteProfile)
        route = .missions
    }

    /// Replaces the taste profile, persists it, and — when a deck is already on screen —
    /// **re-curates it in place** so the change is *felt*: the live candidates re-rank and
    /// re-voice against the new taste without re-fetching the catalog. A no-op deck (nothing
    /// loaded yet) just persists.
    func updateTaste(_ profile: TasteProfile) {
        tasteProfile = profile
        tasteStore.saveProfile(profile)
        guard !candidates.isEmpty else { return }
        Task { await recurateCurrentDeck() }
    }

    /// Re-ranks and re-voices the current candidate set against the latest `tasteProfile`,
    /// preserving the kit and re-dealing the rest in the new order. Used by ``updateTaste(_:)``
    /// so an edit visibly reshapes the deck the user is looking at. Internal (not private) so
    /// tests can drive the re-curate deterministically rather than racing the fire-and-forget
    /// `Task` that ``updateTaste(_:)`` kicks off.
    func recurateCurrentDeck() async {
        guard let task = selectedTask, !candidates.isEmpty else { return }
        isRecurating = true
        defer { isRecurating = false }

        let curated = await curator.curate(candidates, for: activeTaste, mission: task, refinement: nil, recipient: activeRecipientRef)
        // The user may have navigated to another mission while we were re-curating.
        guard selectedTask?.id == task.id else { return }
        candidates = curated.products
        deck = curated.products.filter { !isInKit($0) }
        curatorTier = curated.tier
    }

    // MARK: Conversational refinement

    /// Applies a typed/chip refinement to the dealt deck (the Curate bar's submit). Fire-and-forget
    /// wrapper over ``applyRefinement(text:)`` so the bar stays synchronous; the async core is what
    /// tests drive deterministically.
    func refine(_ text: String) {
        Task { await applyRefinement(text: text) }
    }

    /// Reworks the current deck from a refinement line: interprets it (in the context of the
    /// running conversation) into a ``RefinementDirective``, re-searches + merges only when the
    /// directive carries `addQueries`, then re-curates the working set with the directive so
    /// ranking AND voice honor it. The kit is preserved; the rest is re-dealt in the new order.
    /// Internal (not private) so tests can await it rather than racing the fire-and-forget `Task`.
    func applyRefinement(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = selectedTask, !trimmed.isEmpty, !candidates.isEmpty else { return }

        refinementTurns.append(trimmed)
        isReworking = true
        defer { isReworking = false }

        let interpreted = await refiner.interpret(
            trimmed, conversation: refinementTurns, mission: task, profile: activeTaste
        )
        refinementTier = interpreted.tier
        refinementDirectives.append(interpreted.directive)

        // Pull in new candidates only when the refinement asked for something not in the deck
        // (e.g. "add rain pants"); otherwise re-curate the existing deck in place.
        var working = candidates
        if !interpreted.directive.addQueries.isEmpty, let found = await search(interpreted.directive.addQueries) {
            guard selectedTask?.id == task.id else { return }
            var seen = Set(working.map(\.id))
            working += found.filter { seen.insert($0.id).inserted }
        }

        let context = RefinementContext(directive: interpreted.directive, conversation: refinementTurns)
        let curated = await curator.curate(working, for: activeTaste, mission: task, refinement: context, recipient: activeRecipientRef)
        // The user may have navigated to another mission while we were reworking.
        guard selectedTask?.id == task.id else { return }
        candidates = curated.products
        deck = curated.products.filter { !isInKit($0) }
        curatorTier = curated.tier
        canSaveRefinementToTaste = refinementDirectives.contains { $0.isActionable }
    }

    /// Clears the refinement conversation and restores the deck as first dealt (the
    /// ``baseCandidates`` snapshot), preserving the kit. Synchronous and model-free — the base
    /// deck already carries Crumb's voice, so Reset is an instant undo, not a re-curate.
    func resetRefinements() {
        clearRefinement()
        candidates = baseCandidates
        deck = baseCandidates.filter { !isInKit($0) }
    }

    /// Folds the accumulated refinement into the persisted ``TasteProfile`` so future missions
    /// inherit it (the quiet, opt-in "make this part of your taste"). Primary path: re-read the
    /// refinement text through the injected ``TasteExtractor`` (richer, on-device). Floor: when no
    /// model is available (sim/CI → `nil`), fold the structured directives deterministically so
    /// the save still does something honest and is testable. Persists but does **not** re-curate —
    /// the on-screen deck already reflects the refinement; this is for *next* time.
    func saveRefinementToTaste() async {
        guard canSaveRefinementToTaste, !refinementTurns.isEmpty else { return }
        let combined = refinementTurns.joined(separator: ". ")
        // Fold into whichever taste this mission is curating through: the recipient's during a gift
        // mission (so it sticks next time you shop for them — the owner's profile is untouched), or
        // the owner's otherwise (exactly today's behavior).
        let base = activeTaste
        let extracted = await tasteExtractor.extract(from: combined, base: base)
        let updated = (extracted ?? Self.fold(refinementDirectives, into: base)).normalized

        if let recipient = activeRecipient {
            updateRecipientTaste(recipient, updated)
        } else {
            tasteProfile = updated
            tasteStore.saveProfile(updated)
        }
        canSaveRefinementToTaste = false
    }

    /// Deterministically folds refinement directives into a profile (the no-model floor for
    /// "save to taste"): a price lean nudges `budgetComfort`, an emphasis becomes a leaning, and a
    /// remove hint becomes a "Less …" leaning. The caller normalizes (clamp + dedupe), so repeated
    /// or conflicting asks can't corrupt the profile.
    static func fold(_ directives: [RefinementDirective], into base: TasteProfile) -> TasteProfile {
        var leanings = base.leanings
        var budget = base.budgetComfort
        for directive in directives {
            switch directive.priceDirection {
            case .cheaper: budget -= 0.15
            case .pricier: budget += 0.15
            case .none: break
            }
            let emphasis = directive.emphasis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !emphasis.isEmpty { leanings.append(emphasis) }
            for hint in directive.removeHints { leanings.append("Less \(hint)") }
        }
        return TasteProfile(
            vibe: base.vibe,
            leanings: leanings,
            budgetComfort: budget,
            signatureLine: base.signatureLine
        )
    }

    /// Parses a free-text self-description into a profile via the injected ``TasteExtractor``,
    /// topping up `base` for anything the text doesn't cover. `nil` means "no parse" (no model
    /// available) — the caller keeps the user's hand-set values. Pure delegation, kept here so
    /// the views talk only to the model.
    func extractTaste(from text: String, base: TasteProfile) async -> TasteProfile? {
        await tasteExtractor.extract(from: text, base: base)
    }

    /// Fire-and-forget nudge to wake the (scale-to-zero) broker on launch, so the first live
    /// mission usually loads warm. No-op on the mock.
    func warmUpCatalog() async {
        await ucp.warmUp()
    }

    // MARK: People — the roster you shop for

    /// Opens the "People you shop for" screen (the header affordance).
    func openPeople() {
        route = .people
    }

    /// Adds a new person to the roster and returns them, so a caller (the composer's "Add someone")
    /// can immediately select them. A fresh `id`, the next palette accent by add-order, and a
    /// `createdAt` from the injected clock (deterministic in tests). The taste comes pre-built from
    /// the editor (free-text parse + hand-tuning), normalized before it's stored.
    @discardableResult
    func addRecipient(name: String, relationship: String?, taste: TasteProfile) -> Recipient {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRel = relationship?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accent = Self.recipientAccents[recipients.count % Self.recipientAccents.count]
        let recipient = Recipient(
            id: UUID().uuidString,
            name: trimmedName,
            relationship: (trimmedRel?.isEmpty ?? true) ? nil : trimmedRel,
            taste: taste.normalized,
            accentHex: accent,
            createdAt: clock()
        )
        recipientStore.save(recipient)
        recipients = recipientStore.loadRecipients()
        return recipient
    }

    /// Replaces an existing person (the editor's Save), keeping their identity/accent/createdAt.
    /// Normalizes taste, re-persists, refreshes the roster, and — if they're the active mission's
    /// recipient — updates the live `activeRecipient` so `activeTaste` reflects the edit at once.
    func updateRecipient(_ recipient: Recipient) {
        var updated = recipient
        updated.taste = recipient.taste.normalized
        recipientStore.save(updated)
        recipients = recipientStore.loadRecipients()
        if activeRecipient?.id == updated.id { activeRecipient = updated }
        if composerRecipient?.id == updated.id { composerRecipient = updated }
    }

    /// Folds a new taste into a person's saved profile — the gift-mission "save to taste" target.
    /// Re-persists and keeps the live `activeRecipient` in sync so the on-screen deck's lens updates.
    func updateRecipientTaste(_ recipient: Recipient, _ taste: TasteProfile) {
        var updated = recipient
        updated.taste = taste.normalized
        updateRecipient(updated)
    }

    /// Removes a person from the roster. Clears them from the composer selection and resets a
    /// History filter that was narrowed to them (so the timeline never dangles on an empty filter).
    /// The active mission keeps its snapshot recipient — a mid-mission delete shouldn't change the
    /// deck you're looking at.
    func deleteRecipient(id: String) {
        recipientStore.delete(id: id)
        recipients = recipientStore.loadRecipients()
        if composerRecipient?.id == id { composerRecipient = nil }
        if historyRecipientFilter == .person(id) { historyRecipientFilter = .all }
    }

    /// Parses a free-text description of a person into a ``TasteProfile`` via the injected
    /// ``TasteExtractor`` (the same seam the owner editor uses). Pure delegation — it never touches
    /// the owner profile — so the person editor can reuse `DescribeYourselfCard` unchanged. `nil`
    /// means "no parse" (no model available); the caller keeps the hand-set values.
    func extractRecipientTaste(from text: String, base: TasteProfile) async -> TasteProfile? {
        await tasteExtractor.extract(from: text, base: base)
    }

    // MARK: Curation

    /// The fewest candidates the relevance gate will ever leave on a non-empty result set, so an
    /// over-eager gate can never produce "no matches". Chosen ≥ the largest mock/seed deck so the
    /// scaffold's decks (all relevant to their mission) always pass through untouched; only larger
    /// live decks, where off-topic noise actually appears, get trimmed.
    static let relevanceFloor = 8

    /// Fans the mission's `searchQueries` out to the catalog **in parallel**, dedupes the
    /// union by product id, and hands it to the curator for one ranked deck.
    ///
    /// Failure semantics: each query succeeds or fails independently — a single failed
    /// query just contributes nothing. Only when *every* query errors (broker down /
    /// offline) do we surface ``LoadState/failed`` (retryable), so a real outage is never
    /// mistaken for an empty-but-successful result.
    ///
    /// The mock resolves all of a mission's queries back to the same seed candidates, so
    /// the dedupe collapses them to that mission's curated set — mock behavior is
    /// unchanged.
    func loadCandidates(for task: ShoppingTask) async {
        loadState = .loading

        // Gather the candidate pool — the search + relevance phase. The agentic orchestrator lets
        // the model *drive* the search via Tools (searching each part, reaching past the plan,
        // widening a strong fit) with the relevance guard on every result; it degrades to the
        // deterministic fan-out + gate when no model is up. Either way off-topic items are dropped
        // *before* the curator ranks/voices them, and the floor keeps at least `relevanceFloor`
        // candidates so a real result set never becomes "no matches". Returns nil only on a total
        // catalog outage.
        let gathered = await CrumbTrace.measure("gather", summarize: {
            "queries=\(task.searchQueries.count) candidates=\($0?.products.count ?? 0) agent=\($0?.usedAgent ?? false)"
        }) {
            await orchestrator.gather(for: task, floor: Self.relevanceFloor, using: ucp, gate: relevanceGate)
        }

        // Only mutate if the user is still on this task.
        guard selectedTask?.id == task.id else { return }

        guard let gathered else {
            candidates = []
            deck = []
            baseCandidates = []
            loadState = .failed
            return
        }

        // `curate` both ranks and rewrites each rationale into Crumb's voice, and reports the
        // tier it used so the UI can be honest when it fell back from the AI curator. For a gift
        // mission this curates to the recipient's taste, with gift-framed voice.
        let curated = await CrumbTrace.measure("curate", summarize: {
            "in=\(gathered.products.count) deck=\($0.products.count) tier=\($0.tier.traceLabel)"
        }) {
            await curator.curate(gathered.products, for: activeTaste, mission: task, refinement: nil, recipient: activeRecipientRef)
        }
        guard selectedTask?.id == task.id else { return }
        candidates = curated.products
        deck = curated.products
        baseCandidates = curated.products   // the snapshot Reset restores
        curatorTier = curated.tier
        loadState = .loaded
        // Note: the refinement conversation is reset by `enterPlan` (a new mission) and the
        // screenshot hook, NOT here — clearing it on every (re)load would race a refinement that
        // arrived while an earlier load was still settling.
    }

    /// Fans `queries` out to the catalog **in parallel** and dedupes the union by product id.
    /// Returns `nil` only when *every* query errored (a real outage), so the caller can tell an
    /// outage from a successful-but-empty result. Shared by the initial ``loadCandidates(for:)``
    /// and by an `addQueries` refinement, so both fan out and dedupe identically.
    private func search(_ queries: [String]) async -> [Product]? {
        // The parallel fan-out + dedupe now lives in CrumbKit as `UCPClient.searchUnion`, shared
        // with the deterministic orchestrator so a refinement's `addQueries` search behaves
        // identically to the initial gather.
        await ucp.searchUnion(queries)
    }

    // MARK: Swipe deck

    /// Accept the current top card: add it to the kit and advance the deck.
    func accept(_ product: Product) {
        if !isInKit(product) {
            kit.append(KitItem(product: product))
        }
        advance(past: product)
    }

    /// Skip the current top card without adding it.
    func skip(_ product: Product) {
        advance(past: product)
    }

    private func advance(past product: Product) {
        deck.removeAll { $0.id == product.id }
    }

    func removeFromKit(_ item: KitItem) {
        kit.removeAll { $0.id == item.id }
    }

    /// Re-deal any candidates not currently in the kit (used by "Find more").
    func reshuffleDeck() {
        deck = candidates.filter { !isInKit($0) }
    }

    // MARK: Checkout handoff (per shop)

    /// Resolves the per-shop UCP handoff URL and presents the handoff sheet.
    ///
    /// The sheet is *always* presented so the "Continue" tap is never a silent no-op: if
    /// no handoff target can be resolved (no `continue_url`, no merchant domain, or the
    /// broker errors) the handoff carries a `nil` url and the sheet says so plainly.
    func beginHandoff(for shop: Shop) async {
        let cart = currentCart
        let url = try? await ucp.checkoutHandoff(for: shop, in: cart)
        handoff = Handoff(shop: shop, url: url, items: cart.items(for: shop))
    }
}
