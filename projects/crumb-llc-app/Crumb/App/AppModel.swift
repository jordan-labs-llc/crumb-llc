import Foundation
import Observation
import CrumbKit

/// Top-level navigation state for the Missions → Plan → Curate → Cart flow.
enum Route: Hashable {
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
    var tasteProfile: TasteProfile

    /// Ranked candidate products for the selected mission.
    private(set) var candidates: [Product] = []
    /// The remaining swipe deck (candidates not yet decided on).
    private(set) var deck: [Product] = []
    /// `true` while Crumb is "scanning shops" on the Plan screen.
    private(set) var isScanning = false

    // MARK: Overlay state

    var isShowingTasteProfile = false
    /// When set, the per-shop checkout handoff sheet is presented.
    var handoff: Handoff?

    /// A resolved per-shop checkout handoff (UCP `continue_url`).
    struct Handoff: Identifiable, Hashable {
        let shop: Shop
        let url: URL
        let items: [KitItem]
        var id: String { shop.id }
    }

    // MARK: Dependencies (seams)

    let ucp: any UCPClient
    let curator: any CuratorEngine

    init(
        ucp: any UCPClient,
        curator: any CuratorEngine,
        tasteProfile: TasteProfile = SeedData.defaultTasteProfile
    ) {
        self.ucp = ucp
        self.curator = curator
        self.tasteProfile = tasteProfile
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
        route = .plan
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

    func openCart() {
        route = .cart
    }

    func goToMissions() {
        route = .missions
    }

    /// Steps one level back in the flow.
    func back() {
        switch route {
        case .missions: break
        case .plan: route = .missions
        case .curate: route = .plan
        case .cart: route = .curate
        }
    }

    // MARK: Curation

    private func loadCandidates(for task: ShoppingTask) async {
        isScanning = true
        defer { isScanning = false }
        do {
            let found = try await ucp.searchCatalog(task.id, placements: [.organic])
            let ranked = await curator.rank(found, for: tasteProfile)
            // Only mutate if the user is still on this task.
            guard selectedTask?.id == task.id else { return }
            candidates = ranked
            deck = ranked
        } catch {
            guard selectedTask?.id == task.id else { return }
            candidates = []
            deck = []
        }
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
    func beginHandoff(for shop: Shop) async {
        do {
            let cart = currentCart
            let url = try await ucp.checkoutHandoff(for: shop, in: cart)
            handoff = Handoff(shop: shop, url: url, items: cart.items(for: shop))
        } catch {
            handoff = nil
        }
    }
}
