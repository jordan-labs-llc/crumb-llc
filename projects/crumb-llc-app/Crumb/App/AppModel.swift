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

/// The app's single source of truth.
///
/// `@Observable` (Observation framework) and `@MainActor`. Owns navigation `route`, the
/// selected mission, the user's `kit`, the `tasteProfile`, and the injected `UCPClient`
/// + `CuratorEngine` seams. Registered as an App Intents dependency at launch so Siri /
/// Shortcuts can drive navigation (see ``startMission(matching:)``).
@MainActor
@Observable
final class AppModel {

    // MARK: Navigation

    var route: Route = .missions
    private(set) var selectedTask: ShoppingTask?

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
    private let tasteStore: any TasteStore

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
        tasteExtractor: any TasteExtractor = ManualTasteExtractor()
    ) {
        self.ucp = ucp
        self.curator = curator
        self.tasteStore = tasteStore
        self.tasteExtractor = tasteExtractor

        let stored = tasteStore.loadProfile()
        self.tasteProfile = stored ?? SeedData.defaultTasteProfile
        self.route = stored == nil ? .onboarding : .missions
    }

    // MARK: Derived

    var missions: [ShoppingTask] { SeedData.missions }

    var currentCart: Cart { Cart(items: kit) }

    var accentHex: UInt32 { selectedTask?.accentHex ?? 0x1C4B43 }

    func isInKit(_ product: Product) -> Bool {
        kit.contains { $0.product.id == product.id }
    }

    // MARK: Navigation actions

    /// Selects a mission, routes to Plan, and kicks off the "scanning shops" load.
    func select(_ task: ShoppingTask) {
        selectedTask = task
        kit.removeAll()
        candidates = []
        deck = []
        curatorTier = nil
        loadState = .loading
        route = .plan
        Task { await loadCandidates(for: task) }
    }

    /// Re-runs the candidate load for the current mission (the Plan screen's "Retry").
    func retryLoad() {
        guard let task = selectedTask else { return }
        Task { await loadCandidates(for: task) }
    }

    /// App Intents entry: naive match against seed missions (defaulting to the rainy-hike
    /// task), then route to Plan with that mission preselected.
    func startMission(matching query: String) {
        let task = resolveMission(matching: query)
        select(task)
    }

    /// App Intents entry by resolved mission id (from `ShoppingTaskEntity`). Falls back to
    /// the hike mission if the id is unknown.
    func startMission(missionID id: String) {
        let task = missions.first { $0.id == id } ?? SeedData.hike
        select(task)
    }

    /// Resolves free text to a seed mission, defaulting to the hike mission.
    func resolveMission(matching query: String) -> ShoppingTask {
        let needle = query.lowercased()
        let scored = missions.max { lhs, rhs in
            matchScore(lhs, needle) < matchScore(rhs, needle)
        }
        if let scored, matchScore(scored, needle) > 0 { return scored }
        return SeedData.hike
    }

    private func matchScore(_ task: ShoppingTask, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var score = 0
        if needle.contains(task.id) { score += 3 }
        for word in task.title.lowercased().split(separator: " ") where needle.contains(word) {
            score += 1
        }
        for keyword in task.subtitle.lowercased().split(separator: " ") where needle.contains(keyword) {
            score += 1
        }
        return score
    }

    /// Advances from Plan to the swipe deck.
    func startCurating() {
        route = .curate
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
