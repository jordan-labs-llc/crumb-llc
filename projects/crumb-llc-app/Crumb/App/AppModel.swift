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
    /// The user's taste — the single persisted piece of domain state. Read-only to views;
    /// all edits flow through ``updateTaste(_:)`` so every change is persisted *and* re-curates
    /// the live deck.
    private(set) var tasteProfile: TasteProfile

    /// `true` while a profile edit is re-ranking and re-voicing the on-screen deck. Drives the
    /// Curate screen's "re-reading your taste" shimmer so the personalization is *felt*.
    private(set) var isRecurating = false

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
    private let tasteStore: any TasteStore
    private let recentsStore: any RecentMissionsStore

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
        recentsStore: any RecentMissionsStore = InMemoryRecentMissionsStore()
    ) {
        self.ucp = ucp
        self.curator = curator
        self.tasteStore = tasteStore
        self.tasteExtractor = tasteExtractor
        self.planner = planner
        self.recentsStore = recentsStore

        let stored = tasteStore.loadProfile()
        self.tasteProfile = stored ?? SeedData.defaultTasteProfile
        self.route = stored == nil ? .onboarding : .missions
        self.recentGoals = recentsStore.loadRecents()
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
    func planMission(goal: String) {
        Task { await runPlan(goal: goal) }
    }

    /// Decomposes `goal` via the injected ``MissionPlanner`` and either routes into an editable
    /// Plan (shoppable) or surfaces a friendly decline under the composer (not shoppable). A
    /// shoppable goal is also recorded in recents. Internal (not private) so tests can await it
    /// rather than racing the fire-and-forget `Task`.
    func runPlan(goal: String) async {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPlanning = true
        planDecline = nil
        defer { isPlanning = false }

        let planned = await planner.plan(goal: trimmed, profile: tasteProfile)
        if let task = planned.task {
            recentsStore.addRecent(trimmed)
            recentGoals = recentsStore.loadRecents()
            plannerTier = planned.tier
            enterPlan(with: task)
        } else {
            planDecline = planned.decline
                ?? "I'm a shopping curator — hand me something to shop for."
        }
    }

    /// Sets up the Plan screen for `task`: seeds the editable parts, resets the deck, and routes
    /// to Plan **without** searching yet (the search runs on "Curate my kit", after edits).
    func enterPlan(with task: ShoppingTask) {
        selectedTask = task
        draftParts = Self.draftParts(from: task)
        kit.removeAll()
        candidates = []
        deck = []
        curatorTier = nil
        loadState = .idle
        planDirty = true
        route = .plan
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
    #endif

    func openCart() {
        route = .cart
    }

    func goToMissions() {
        route = .missions
    }

    /// Steps one level back in the flow.
    func back() {
        switch route {
        case .onboarding, .missions: break  // roots — nothing to step back to
        case .plan: route = .missions
        case .curate: route = .plan
        case .cart: route = .curate
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

        let curated = await curator.curate(candidates, for: tasteProfile, mission: task)
        // The user may have navigated to another mission while we were re-curating.
        guard selectedTask?.id == task.id else { return }
        candidates = curated.products
        deck = curated.products.filter { !isInKit($0) }
        curatorTier = curated.tier
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

    // MARK: Curation

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
        let queries = task.searchQueries.isEmpty ? [task.id] : task.searchQueries

        // Parallel fan-out. `try?` keeps a failed query from cancelling its siblings;
        // a failure surfaces as a `nil` batch.
        let batches: [[Product]?] = await withTaskGroup(of: [Product]?.self) { group in
            for query in queries {
                group.addTask { [ucp] in
                    try? await ucp.searchCatalog(query, placements: [.organic])
                }
            }
            var collected: [[Product]?] = []
            for await batch in group { collected.append(batch) }
            return collected
        }

        // Only mutate if the user is still on this task.
        guard selectedTask?.id == task.id else { return }

        let succeeded = batches.compactMap { $0 }
        if succeeded.isEmpty {
            candidates = []
            deck = []
            loadState = .failed
            return
        }

        var seen = Set<Product.ID>()
        let union = succeeded.flatMap { $0 }.filter { seen.insert($0.id).inserted }
        // `curate` both ranks and rewrites each rationale into Crumb's voice, and reports the
        // tier it used so the UI can be honest when it fell back from the AI curator.
        let curated = await curator.curate(union, for: tasteProfile, mission: task)
        guard selectedTask?.id == task.id else { return }
        candidates = curated.products
        deck = curated.products
        curatorTier = curated.tier
        loadState = .loaded
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
