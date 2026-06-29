import Testing
import Foundation
import CrumbKit
@testable import Crumb

/// App-level smoke tests (run via Xcode). These exercise `AppModel` routing on top of the
/// mock UCP client — no network, no secrets.
@Suite("Crumb app smoke tests")
struct CrumbTests {

    @Test("A returning user (saved profile) starts on Missions with three seed missions")
    @MainActor
    func launchesToMissions() {
        // A persisted profile is the "returning user" signal — straight to Missions.
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        #expect(model.route == .missions)
        #expect(model.missions.count == 3)
        #expect(model.kit.isEmpty)
    }

    // MARK: - Free-text planning (the composer / Siri entry)

    @Test("Planning a shoppable goal routes to an editable Plan and records a recent")
    @MainActor
    func planRoutesToEditablePlan() async {
        let recents = InMemoryRecentMissionsStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            recentsStore: recents
        )
        await model.runPlan(goal: "Set up my pour-over corner")

        #expect(model.route == .plan)
        #expect(model.selectedTask != nil)
        #expect(!model.draftParts.isEmpty)              // an editable plan was produced
        #expect(model.planDecline == nil)
        #expect(model.recentGoals.first == "Set up my pour-over corner") // recorded, most-recent-first
    }

    @Test("A non-shopping goal declines gracefully and stays on Missions")
    @MainActor
    func planDeclinesNonShoppingGoal() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "what is the weather?")

        #expect(model.route == .missions)              // no navigation into an empty plan
        #expect(model.selectedTask == nil)
        #expect(model.planDecline != nil)              // a friendly message instead
        #expect(model.recentGoals.isEmpty)             // nonsense isn't remembered
    }

    @Test("Editing the plan then curating searches the edited queries and advances to Curate")
    @MainActor
    func editPlanThenCurate() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "Set up my pour-over corner")
        let firstPart = try! #require(model.draftParts.first)
        model.updatePart(firstPart, label: "gooseneck kettle")    // reword → re-derives the query
        model.addPart(label: "burr coffee grinder")

        await model.beginCuration()

        #expect(model.route == .curate)
        #expect(model.loadState == .loaded)
        #expect(!model.candidates.isEmpty)             // the mock resolved the edited queries
    }

    @Test("Removing a part drops it from the draft plan")
    @MainActor
    func removePart() async {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        await model.runPlan(goal: "Make my desk feel calm")
        let count = model.draftParts.count
        let part = try! #require(model.draftParts.first)
        model.removePart(part)
        #expect(model.draftParts.count == count - 1)
        #expect(!model.draftParts.contains(part))
    }

    @Test("Accepting a product adds it to the kit once")
    @MainActor
    func acceptBuildsKit() throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        let product = try #require(SeedData.hikeProducts.first)
        model.accept(product)
        model.accept(product) // idempotent by product id
        #expect(model.kit.count == 1)
        #expect(model.isInKit(product))
    }

    @Test("MockUCPClient.searchCatalog(\"hike\") returns the hike candidates")
    func searchHike() async throws {
        let hits = try await MockUCPClient().searchCatalog("hike", placements: [.organic])
        #expect(hits.count == 6)
        #expect(hits.allSatisfy { $0.id.hasPrefix("hike.") })
    }

    @Test("A mission's search queries all resolve to its curated deck (mock fan-out)")
    func mockResolvesSearchQueries() async throws {
        let mock = MockUCPClient()
        for query in SeedData.hike.searchQueries {
            let hits = try await mock.searchCatalog(query, placements: [.organic])
            #expect(hits.allSatisfy { $0.id.hasPrefix("hike.") }, "query: \(query)")
            #expect(!hits.isEmpty, "query: \(query)")
        }
    }

    @Test("loadCandidates fans queries out in parallel and dedupes by product id")
    @MainActor
    func fanOutDedupes() async {
        let p1 = Self.fakeProduct("a")
        let p2 = Self.fakeProduct("b")
        let p3 = Self.fakeProduct("c")
        let fake = FakeUCP(byQuery: [
            "q1": [p1, p2],
            "q2": [p2, p3],   // p2 overlaps q1 — must dedupe to one
        ])
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.select(task)               // sets selectedTask so the load isn't skipped
        await model.loadCandidates(for: task)

        #expect(model.loadState == .loaded)
        #expect(model.candidates.count == 3)
        #expect(Set(model.candidates.map(\.id)) == ["a", "b", "c"])
    }

    @Test("A query that errors still contributes its siblings' results")
    @MainActor
    func partialFailureKeepsResults() async {
        let fake = FakeUCP(byQuery: ["q1": [Self.fakeProduct("a")]], failing: ["q2"])
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.select(task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .loaded)
        #expect(model.candidates.map(\.id) == ["a"])
    }

    @Test("When every query errors, the load fails (distinct from empty)")
    @MainActor
    func allFailuresSurfaceError() async {
        let fake = FakeUCP(byQuery: [:], failAll: true)
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.select(task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .failed)
        #expect(model.loadFailed)
        #expect(model.candidates.isEmpty)
    }

    @Test("beginHandoff presents the sheet with a nil url when no link resolves")
    @MainActor
    func handoffPresentsHonestSheet() async {
        // FakeUCP always throws emptyShopHandoff — the sheet must still present (no silent
        // no-op), carrying a nil url so the view can show the honest "no link" state.
        let model = AppModel(ucp: FakeUCP(byQuery: [:]), curator: RuleBasedCurator())
        let product = Self.fakeProduct("a")
        model.accept(product)

        await model.beginHandoff(for: product.shop)

        let handoff = model.handoff
        #expect(handoff != nil)
        #expect(handoff?.url == nil)
        #expect(handoff?.items.count == 1)
    }

    // MARK: - Taste capture & onboarding

    @Test("First run (no saved profile) opens onboarding")
    @MainActor
    func firstRunOpensOnboarding() {
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore()   // empty → first run
        )
        #expect(model.route == .onboarding)
        // The seed profile is the editable starting point until they finish.
        #expect(model.tasteProfile == SeedData.defaultTasteProfile)
    }

    @Test("Completing onboarding persists the profile and routes into the app")
    @MainActor
    func completeOnboardingPersists() {
        let store = InMemoryTasteStore()
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        let built = TasteProfile(
            vibe: ["Bold"], leanings: ["Tech-forward"],
            budgetComfort: 0.9, signatureLine: "Give me the best."
        )

        model.completeOnboarding(with: built)

        #expect(model.route == .missions)
        #expect(model.tasteProfile == built)
        #expect(store.loadProfile() == built)            // survives relaunch
    }

    @Test("Skipping onboarding still persists a profile so it doesn't reappear")
    @MainActor
    func skipOnboardingPersistsSeed() {
        let store = InMemoryTasteStore()
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)

        model.skipOnboarding()

        #expect(model.route == .missions)
        #expect(store.loadProfile() == SeedData.defaultTasteProfile)
        // A fresh launch over the same store now sees a returning user.
        let relaunched = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        #expect(relaunched.route == .missions)
    }

    @Test("Editing taste persists it and re-curates the live deck (personalization is felt)")
    @MainActor
    func updateTasteRecuratesDeck() async {
        let store = InMemoryTasteStore(Self.thrifty)
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: ProfileSortCurator(),
            tasteStore: store
        )
        model.select(SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        // Thrifty profile → ProfileSortCurator deals the deck id-ascending.
        let before = model.deck.map(\.id)
        #expect(before == before.sorted())

        // Flip to splurge and re-curate the deck in place.
        model.updateTaste(Self.splurge)
        await model.recurateCurrentDeck()

        let after = model.deck.map(\.id)
        #expect(after == before.sorted(by: >))       // visibly re-ranked (now descending)
        #expect(Set(after) == Set(before))           // same set, nothing lost
        #expect(model.tasteProfile == Self.splurge)
        #expect(store.loadProfile() == Self.splurge) // and persisted
    }

    @Test("Editing taste with nothing loaded just persists (no deck to re-curate)")
    @MainActor
    func updateTasteWithoutDeckPersists() {
        let store = InMemoryTasteStore(SeedData.defaultTasteProfile)
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        #expect(model.candidates.isEmpty)

        model.updateTaste(Self.splurge)

        #expect(model.tasteProfile == Self.splurge)
        #expect(store.loadProfile() == Self.splurge)
        #expect(model.isRecurating == false)
    }

    private static let thrifty = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.1, signatureLine: ""
    )
    private static let splurge = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.9, signatureLine: ""
    )

    // MARK: - Fixtures

    private static func fakeProduct(_ id: String) -> Product {
        Product(
            id: id, name: id, shop: Shop(id: "s", name: "Shop"), price: 10,
            rating: 0, reviews: 0, rationale: "", symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: 10)]
        )
    }

    private static func fakeTask(queries: [String]) -> ShoppingTask {
        ShoppingTask(
            id: "fake", title: "Fake", subtitle: "", plan: [], curatorNote: "",
            accentHex: 0, candidateIDs: [], searchQueries: queries
        )
    }
}

/// A test curator whose order depends on the profile, so a taste change produces a *visible*
/// re-rank: low budget comfort deals id-ascending, high deals id-descending. (Deterministic,
/// no model — the whole point is to prove `updateTaste` re-curates against the new profile.)
private struct ProfileSortCurator: CuratorEngine {
    func plan(for task: ShoppingTask) async -> [String] { task.plan }

    func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        profile.budgetComfort < 0.5
            ? products.sorted { $0.id < $1.id }
            : products.sorted { $0.id > $1.id }
    }

    func rationale(for product: Product, profile: TasteProfile) -> String { product.rationale }

    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask
    ) async -> CuratedDeck {
        CuratedDeck(products: await rank(products, for: profile), tier: .onDevice)
    }
}

/// An in-test ``UCPClient`` that maps queries to canned results and can fail selectively.
private struct FakeUCP: UCPClient {
    let byQuery: [String: [Product]]
    var failing: Set<String> = []
    var failAll = false

    func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product] {
        if failAll || failing.contains(query) {
            throw UCPError.productNotFound(query)
        }
        return byQuery[query] ?? []
    }

    func product(id: Product.ID) async throws -> Product {
        throw UCPError.productNotFound(id)
    }

    func assembleCart(_ items: [KitItem]) async throws -> Cart { Cart(items: items) }

    func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        throw UCPError.emptyShopHandoff(shop.id)
    }
}
