import Testing
import Foundation
import AppIntents
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

    // MARK: - Onboarding "let the goal lead" fast path (#28)

    @Test("A first-run user can start from a goal: it plans straight to Curate and persists a profile")
    @MainActor
    func goalFirstOnboardingRoutesToPlan() async {
        let store = InMemoryTasteStore()   // no saved profile → first-run onboarding
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        #expect(model.route == .onboarding)

        await model.runOnboardingGoal("Set up my pour-over corner")

        #expect(model.route == .plan)                  // led straight into the editable plan
        #expect(model.selectedTask != nil)
        #expect(store.loadProfile() != nil)            // onboarding completed + persisted (won't reappear)
    }

    @Test("A first-run user is seeded with taste inferred from the goal")
    @MainActor
    func goalFirstSeedsTasteFromGoal() async {
        let store = InMemoryTasteStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: store, tasteExtractor: MarkerTasteExtractor()
        )
        await model.runOnboardingGoal("Set up my pour-over corner")

        // The injected extractor read the goal into the profile — the goal-first path wired it in.
        #expect(model.tasteProfile.vibe.contains("GoalSeeded"))
        #expect(store.loadProfile()?.vibe.contains("GoalSeeded") == true)
    }

    @Test("A first-run user with a non-shoppable goal still finishes onboarding, not stranded")
    @MainActor
    func goalFirstNonShoppableCompletesOnboarding() async {
        let store = InMemoryTasteStore()
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)

        await model.runOnboardingGoal("what is the weather?")

        #expect(model.route == .missions)              // dropped into the app, not left on onboarding
        #expect(model.selectedTask == nil)
        #expect(model.planDecline != nil)              // the friendly decline, shown on Missions
        #expect(store.loadProfile() != nil)            // onboarding still persisted
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

    @Test("Streaming curate navigates to Curate and settles to the ranked deck")
    @MainActor
    func streamingLoadSettlesToRankedDeck() async {
        // A seed mission on the mock: picks stream in, we navigate to Curate on the first, then the
        // deck settles to the curator's ranked order once curation finishes.
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(),
                             tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile))
        model.enterPlan(with: SeedData.coffee)   // sets selectedTask + route = .plan
        await model.loadCandidates(for: SeedData.coffee)

        #expect(model.route == .curate)                 // navigated (on the first streamed pick)
        #expect(model.loadState == .loaded)             // then settled
        #expect(!model.deck.isEmpty)
        // No swipes happened, so the settled deck is the full ranked deck — same set and order as
        // the curated candidates.
        #expect(model.deck.map(\.id) == model.candidates.map(\.id))
        #expect(Set(model.deck.map(\.id)) == Set(SeedData.coffeeProducts.map(\.id)))
    }

    @Test("First streamed pick flips loadState from loading to refining, then settles to loaded (#57)")
    @MainActor
    func firstPickEntersRefiningThenSettles() async {
        // A slow curator keeps the settle running long enough that the deck is genuinely actionable
        // (refining) before it settles — the state the indefinite-spinner bug lived in.
        let model = AppModel(ucp: MockUCPClient(), curator: DelayingCurator(delay: .milliseconds(150)),
                             tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile))
        model.enterPlan(with: SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)
        // By the time the call returns we've settled; the deck is the model-ranked one (not fallback).
        #expect(model.loadState == .loaded)
        #expect(model.route == .curate)
        #expect(!model.deck.isEmpty)
        #expect(model.curatorTier == .onDevice)          // the slow curation completed in time
        #expect(model.curationRefiningOvertime == false) // reset on settle
    }

    @Test("A curation that overruns the settle deadline settles the streamed deck, not a spinner (#57)")
    @MainActor
    func settleDeadlineFallsBackToStreamedDeck() async {
        // The curator stalls well past the (shrunk) hard deadline — the load must still settle with
        // the streamed, deterministically-voiced deck instead of hanging in `.refining` forever.
        let model = AppModel(ucp: MockUCPClient(), curator: DelayingCurator(delay: .seconds(5)),
                             tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile))
        model.curationSettleWindow = 0.02
        model.curationSettleDeadline = 0.1
        model.enterPlan(with: SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)

        #expect(model.loadState == .loaded)                        // settled, never stuck refining
        #expect(model.route == .curate)
        #expect(!model.deck.isEmpty)                               // the streamed deck is usable
        #expect(model.curatorTier == .ruleBased(.modelNotReady))  // honest fallback note is surfaced
        #expect(model.curatorFallbackNote != nil)
    }

    @Test("A total catalog outage fails without navigating away from Plan")
    @MainActor
    func streamingOutageStaysOnPlan() async {
        let fake = FakeUCP(byQuery: [:], failAll: true)
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .failed)
        #expect(model.deck.isEmpty)
        #expect(model.route == .plan)   // nothing streamed → never navigated
    }

    @Test("settledDeck keeps undecided cards in ranked order and drops swiped-away ones")
    func settledDeckShaping() {
        let settled = [Self.fakeProduct("a"), Self.fakeProduct("b"),
                       Self.fakeProduct("c"), Self.fakeProduct("d")]   // ranked order
        // The user swiped a and d away while streaming; b and c remain (c is on top).
        let current = [Self.fakeProduct("c"), Self.fakeProduct("b")]
        let out = AppModel.settledDeck(settled, keepingUndecidedFrom: current)
        #expect(out.map(\.id) == ["b", "c"])   // undecided only, in the settled (ranked) order — not floated
        // Nothing streamed yet → the full ranked deck is used unchanged.
        #expect(AppModel.settledDeck(settled, keepingUndecidedFrom: []).map(\.id) == ["a", "b", "c", "d"])
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

    @Test("Single-item handoff checks out exactly one product, even when options share a shop (#60)")
    @MainActor
    func singleItemHandoffIsolatesOneProduct() async throws {
        // Both fake products live in the same shop; the per-shop handoff would take both, but the
        // single-product "Buy this" must carry only the one the user chose.
        let model = AppModel(ucp: FakeUCP(byQuery: [:]), curator: RuleBasedCurator())
        model.accept(Self.fakeProduct("a"))
        model.accept(Self.fakeProduct("b"))
        #expect(model.currentCart.items(for: Shop(id: "s", name: "Shop")).count == 2)

        let itemA = try #require(model.kit.first { $0.product.id == "a" })
        await model.beginHandoff(for: itemA)

        let handoff = try #require(model.handoff)
        #expect(handoff.items.count == 1)
        #expect(handoff.items.first?.product.id == "a")
        #expect(handoff.shop.id == "s")
        #expect(handoff.url == nil)   // FakeUCP resolves no link — still presents honestly
    }

    // MARK: - Conversational refinement

    @Test("A refinement reworks the deck in place, preserving the kit")
    @MainActor
    func refineReworksDeckInPlace() async {
        // ScriptedRefiner emits a price-cheaper directive; the rule-based curate default sorts the
        // deck by ascending price, so the rework is visible and deterministic.
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(priceDirection: .cheaper))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let kept = try! #require(model.deck.first)
        model.accept(kept)                                  // one item in the kit

        await model.applyRefinement(text: "make it cheaper")

        let prices = model.deck.map(\.price)
        #expect(prices == prices.sorted(by: <))             // re-sorted ascending
        #expect(model.isInKit(kept))                        // kit preserved
        #expect(!model.deck.contains { $0.id == kept.id })  // kit item not re-dealt
        #expect(model.refinementTurns == ["make it cheaper"])
        #expect(model.canSaveRefinementToTaste)             // the offer is now available
    }

    @Test("An addQueries refinement searches and merges new items, deduped")
    @MainActor
    func refineAddQueriesMergesNewItems() async {
        let base = Self.fakeProduct("base")
        let extra = Self.fakeProduct("extra")
        let fake = FakeUCP(byQuery: ["base": [base], "rain pants": [extra, base]]) // base overlaps → dedupe
        let model = AppModel(
            ucp: fake, curator: RuleBasedCurator(),
            refiner: ScriptedRefiner(.init(addQueries: ["rain pants"]))
        )
        let task = Self.fakeTask(queries: ["base"])
        model.enterPlan(with: task)      // sets selectedTask without a background load (avoids a race)
        await model.loadCandidates(for: task)
        #expect(model.candidates.map(\.id) == ["base"])

        await model.applyRefinement(text: "add rain pants")

        #expect(Set(model.candidates.map(\.id)) == ["base", "extra"]) // merged, deduped
    }

    @Test("Reset restores the originally dealt deck and clears the conversation")
    @MainActor
    func resetRestoresBaseDeck() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(removeHints: ["down"]))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let before = model.deck.map(\.id)

        await model.applyRefinement(text: "no down")
        model.resetRefinements()

        #expect(model.deck.map(\.id) == before)             // back to the original order
        #expect(model.refinementTurns.isEmpty)
        #expect(!model.canSaveRefinementToTaste)
    }

    @Test("Entering a new mission clears the refinement conversation (ephemeral)")
    @MainActor
    func enterPlanClearsRefinement() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(emphasis: "warmer"))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "warmer")
        #expect(!model.refinementTurns.isEmpty)

        await model.runPlan(goal: "Set up my pour-over corner")   // new mission

        #expect(model.refinementTurns.isEmpty)
        #expect(model.refinementTier == nil)
        #expect(!model.canSaveRefinementToTaste)
    }

    @Test("Save to taste folds the refinement in via the extractor when a model is available")
    @MainActor
    func saveToTasteUsesExtractor() async {
        let store = InMemoryTasteStore(SeedData.defaultTasteProfile)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: store,
            tasteExtractor: StubExtractor(Self.splurge),     // a model "read" of the refinement
            refiner: ScriptedRefiner(.init(emphasis: "warmer"))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "warmer")

        await model.saveRefinementToTaste()

        #expect(model.tasteProfile == Self.splurge.normalized)
        #expect(store.loadProfile() == Self.splurge.normalized)  // persisted for future missions
        #expect(!model.canSaveRefinementToTaste)                 // offer consumed
    }

    @Test("Save to taste falls back to a deterministic fold when no model is available")
    @MainActor
    func saveToTasteDeterministicFold() async {
        let store = InMemoryTasteStore(Self.balanced)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: store,
            tasteExtractor: ManualTasteExtractor(),          // nil → deterministic floor
            refiner: ScriptedRefiner(.init(emphasis: "warmer tones", priceDirection: .cheaper))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "warmer tones, cheaper")

        await model.saveRefinementToTaste()

        #expect(model.tasteProfile.budgetComfort < Self.balanced.budgetComfort) // cheaper nudged down
        #expect(model.tasteProfile.leanings.contains("warmer tones"))           // emphasis → leaning
        #expect(store.loadProfile() == model.tasteProfile)                      // persisted
    }

    private static let balanced = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.5, signatureLine: ""
    )

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
        model.enterPlan(with: SeedData.hike)
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

    // MARK: - History

    @Test("Reaching the cart with a kit writes a snapshotted history entry (recap on the floor)")
    @MainActor
    func reachingCartWritesHistory() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))

        await model.recordCurrentKit()                 // the openCart write path

        #expect(model.historyEntries.count == 1)
        let entry = try #require(model.historyEntries.first)
        #expect(entry.items.count == 1)
        #expect(entry.title == SeedData.hike.title)
        #expect(!entry.recapTag.isEmpty)               // recap written (rule-based on CI)
        #expect(!entry.recapLine.isEmpty)
        #expect(!entry.handedOff)                       // not yet handed off
        #expect(store.loadEntries().count == 1)         // persisted to the store
    }

    @Test("An abandoned plan with nothing kept records no history")
    @MainActor
    func emptyKitWritesNothing() async {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)

        await model.recordCurrentKit()                 // no items kept

        #expect(model.historyEntries.isEmpty)
        #expect(store.loadEntries().isEmpty)
    }

    @Test("Re-reaching the cart in one session updates the same entry, not a duplicate")
    @MainActor
    func reReachingCartUpdatesSameEntry() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()
        let firstID = try #require(model.historyEntries.first).id

        model.accept(try #require(model.deck.first))   // keep one more, same session
        await model.recordCurrentKit()

        #expect(model.historyEntries.count == 1)       // upsert, not a new entry
        #expect(model.historyEntries.first?.id == firstID)
        #expect(model.historyEntries.first?.items.count == 2)
    }

    @Test("Building a kit for the same goal in a new session makes a second, distinct entry")
    @MainActor
    func newSessionMakesNewEntry() async throws {
        var clockValue = Date(timeIntervalSinceReferenceDate: 1_000)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            clock: { clockValue }
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        clockValue = clockValue.addingTimeInterval(60)  // a later, distinct session
        model.enterPlan(with: SeedData.hike)            // same goal, new session
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        #expect(model.historyEntries.count == 2)        // two distinct shopping sessions
    }

    @Test("Following a real checkout link flips this session's outcome flag (and persists it)")
    @MainActor
    func handoffFollowedFlipsOutcome() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()
        #expect(model.historyEntries.first?.handedOff == false)

        model.recordHandoffFollowed()

        #expect(model.historyEntries.first?.handedOff == true)
        #expect(store.loadEntries().first?.handedOff == true)
    }

    @Test("Delete removes one entry; clear empties the whole history")
    @MainActor
    func deleteAndClearHistory() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        for mission in [SeedData.hike, SeedData.coffee] {
            model.enterPlan(with: mission)
            await model.loadCandidates(for: mission)
            model.accept(try #require(model.deck.first))
            await model.recordCurrentKit()
        }
        #expect(model.historyEntries.count == 2)

        model.deleteHistoryEntry(try #require(model.historyEntries.first))
        #expect(model.historyEntries.count == 1)

        model.clearHistory()
        #expect(model.historyEntries.isEmpty)
    }

    @Test("Plan-this-again re-plans the goal into an editable plan and clears the detail state")
    @MainActor
    func planAgainReplansGoal() async {
        let seeded = SeedData.historyEntries(now: Date())
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: InMemoryHistoryStore(seeded)
        )
        let entry = model.historyEntries.first!
        model.openHistoryDetail(entry)
        model.beginReshop(entry)
        model.planAgain(entry)                          // clears overlay state synchronously

        #expect(model.reshopEntry == nil)
        #expect(model.selectedHistoryEntry == nil)

        // The substance of "plan again": routing the goal back through the planner yields a plan.
        await model.runPlan(goal: entry.goal)
        #expect(model.route == .plan)
        #expect(model.selectedTask != nil)
    }

    @Test("Aggregate history stats are exposed for the timeline header")
    @MainActor
    func historyStatsExposed() {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: InMemoryHistoryStore(SeedData.historyEntries(now: Date()))
        )
        #expect(model.historyStats.kitCount == 5)       // the five seeded missions
        #expect(model.historyStats.isMilestone)         // 5 is a milestone
        #expect(model.historyStats.itemCount > 0)
        #expect(model.historyStats.shopCount > 0)
    }

    @Test("Re-reaching the cart with an unchanged kit does not regenerate the recap (no jitter)")
    @MainActor
    func recapStableOnUnchangedReReach() async throws {
        let writer = CountingRecapWriter()                // a fresh tag/line every call
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            recapWriter: writer
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()
        let firstLine = try #require(model.historyEntries.first).recapLine
        let callsAfterFirst = writer.calls

        await model.recordCurrentKit()                    // same kit, re-reach

        #expect(model.historyEntries.first?.recapLine == firstLine) // recap unchanged
        #expect(writer.calls == callsAfterFirst)                    // writer not called again
    }

    @Test("A saved entry keeps the user's original goal text, not the title-cased task title")
    @MainActor
    func savedGoalIsTheOriginalText() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "pack me for a rainy weekend hike")  // composer path
        await model.beginCuration()
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        let entry = try #require(model.historyEntries.first)
        #expect(entry.goal == "pack me for a rainy weekend hike")      // verbatim, for plan-again
        #expect(entry.title != entry.goal)                             // title is the cased derivation
    }

    // MARK: - Gift missions (shop for someone else)

    /// A recipient whose taste is *distinct* from the owner, so a gift mission's lens is observable.
    private static func giftRecipient() -> Recipient {
        Recipient(
            id: "mom", name: "Mom", relationship: "my mom",
            taste: Self.splurge,                       // ≠ the owner's default profile
            accentHex: 0x9A6A4F, createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    @Test("A gift mission curates through the recipient's taste, not the owner's")
    @MainActor
    func giftMissionUsesRecipientTaste() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: ProfileSortCurator(),   // order encodes which taste ran
            tasteStore: InMemoryTasteStore(Self.thrifty)           // owner = thrifty → id-ascending
        )
        let mom = Self.giftRecipient()                             // splurge → id-descending
        model.enterPlan(with: SeedData.hike, recipient: mom)
        #expect(model.activeRecipient?.id == "mom")
        #expect(model.activeTaste == Self.splurge)                 // the switch resolves to her taste

        await model.loadCandidates(for: SeedData.hike)
        let ids = model.deck.map(\.id)
        #expect(ids == ids.sorted(by: >))                          // ranked by *her* (splurge) taste
        #expect(model.tasteProfile == Self.thrifty)                // owner profile untouched
    }

    @Test("Selecting Yourself behaves exactly as today (no recipient, owner taste)")
    @MainActor
    func yourselfIsRegressionFree() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: ProfileSortCurator(),
            tasteStore: InMemoryTasteStore(Self.thrifty)
        )
        model.enterPlan(with: SeedData.hike)                       // no recipient
        #expect(model.activeRecipient == nil)
        #expect(model.activeTaste == Self.thrifty)
        #expect(model.activeRecipientRef == nil)
        await model.loadCandidates(for: SeedData.hike)
        let ids = model.deck.map(\.id)
        #expect(ids == ids.sorted())                               // owner (thrifty) order
    }

    @Test("A gift kit records the recipient on its history entry; an owner kit records none")
    @MainActor
    func giftKitTagsHistory() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike, recipient: Self.giftRecipient())
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        let entry = try #require(model.historyEntries.first)
        #expect(entry.recipient?.id == "mom")
        #expect(entry.recipient?.name == "Mom")
        #expect(entry.recapLine.contains("a gift for Mom"))        // deterministic gift floor (CI)
    }

    @Test("Save-to-taste during a gift mission folds into the recipient; the owner is untouched")
    @MainActor
    func saveToTasteTargetsRecipient() async {
        let recipientStore = InMemoryRecipientStore([Self.giftRecipient()])
        let tasteStore = InMemoryTasteStore(Self.balanced)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: tasteStore,
            tasteExtractor: ManualTasteExtractor(),                // nil → deterministic fold
            refiner: ScriptedRefiner(.init(emphasis: "ceramic", priceDirection: .cheaper)),
            recipientStore: recipientStore
        )
        let mom = try! #require(model.recipients.first)
        model.enterPlan(with: SeedData.hike, recipient: mom)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "more ceramic, cheaper")

        #expect(model.saveToTasteLabel == "Make this part of Mom's taste")
        await model.saveRefinementToTaste()

        let saved = try! #require(recipientStore.loadRecipients().first { $0.id == "mom" })
        #expect(saved.taste.leanings.contains("ceramic"))          // folded into *her* profile…
        #expect(model.activeRecipient?.taste.leanings.contains("ceramic") == true) // …and the live lens
        #expect(tasteStore.loadProfile() == Self.balanced)         // owner profile untouched
    }

    @Test("People CRUD: add assigns id+accent, edit replaces, delete removes (and clears composer)")
    @MainActor
    func peopleRosterCRUD() {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        #expect(model.recipients.isEmpty)

        let dad = model.addRecipient(name: "Dad", relationship: "my dad", taste: Self.splurge)
        #expect(model.recipients.map(\.name) == ["Dad"])
        #expect(!dad.id.isEmpty)
        #expect(dad.accentHex == AppModel.recipientAccents[0])

        var edited = dad
        edited.name = "Papa"
        model.composerRecipient = dad
        model.updateRecipient(edited)
        #expect(model.recipients.first?.name == "Papa")
        #expect(model.composerRecipient?.name == "Papa")           // live selection follows the edit

        model.deleteRecipient(id: dad.id)
        #expect(model.recipients.isEmpty)
        #expect(model.composerRecipient == nil)                    // selection cleared on delete
    }

    @Test("Plan-this-again for a gift entry re-targets the same person when still in the roster")
    @MainActor
    func planAgainResolvesRecipient() async {
        let recipientStore = InMemoryRecipientStore([Self.giftRecipient()])
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            recipientStore: recipientStore
        )
        let mom = try! #require(model.recipients.first)
        model.enterPlan(with: SeedData.coffee, recipient: mom)
        await model.loadCandidates(for: SeedData.coffee)
        model.accept(model.deck.first!)
        await model.recordCurrentKit()
        let entry = try! #require(model.historyEntries.first)

        await model.runPlan(goal: entry.goal, for: model.recipients.first { $0.id == entry.recipient?.id })
        #expect(model.activeRecipient?.id == "mom")                // re-planned for Mom
    }

    @Test("The History recipient filter narrows the timeline and the stats header")
    @MainActor
    func historyFilterNarrows() {
        let momRef = RecipientRef(id: "mom", name: "Mom", accentHex: 0x9A6A4F)
        let store = InMemoryHistoryStore([
            Self.historyFixture(id: "gift", recipient: momRef),
            Self.historyFixture(id: "owned", recipient: nil),
        ])
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        #expect(model.historyFacets.map(\.id) == ["all", "yourself", "person-mom"])
        #expect(model.filteredHistoryEntries.count == 2)

        model.historyRecipientFilter = .person("mom")
        #expect(model.filteredHistoryEntries.map(\.id) == ["gift"])
        #expect(model.historyStats.kitCount == 1)                  // stats follow the filter
    }

    private static func historyFixture(id: String, recipient: RecipientRef?) -> HistoryEntry {
        HistoryEntry(
            id: id, goal: "g", title: "T", subtitle: "s", plan: ["a"], searchQueries: ["a"],
            curatorNote: "", accentHex: 0, recapTag: "Tag", recapLine: "Line",
            items: [HistoryItem(productID: "p", name: "Item", shop: Shop(id: "s", name: "Shop"),
                                price: 10, variantTitle: "Standard")],
            recipient: recipient, handedOff: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

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
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        CuratedDeck(products: await rank(products, for: profile), tier: .onDevice)
    }
}

/// A curator that stalls before ranking, standing in for a slow/hung on-device model turn so the
/// settle watchdog + hard deadline (#57) can be exercised deterministically. It delegates voice and
/// ranking to ``RuleBasedCurator`` after the delay, and reports the on-device tier (so a *successful*
/// slow curation is distinguishable from the deterministic fallback).
private struct DelayingCurator: CuratorEngine {
    let delay: Duration
    private let inner = RuleBasedCurator()

    func plan(for task: ShoppingTask) async -> [String] { await inner.plan(for: task) }

    func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        try? await Task.sleep(for: delay)
        return await inner.rank(products, for: profile)
    }

    func rationale(for product: Product, profile: TasteProfile) -> String {
        inner.rationale(for: product, profile: profile)
    }

    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        let ranked = await rank(products, for: profile)   // the delay lives here
        let voiced = ranked.map { $0.withRationale(inner.rationale(for: $0, profile: profile, recipient: recipient, mission: mission)) }
        return CuratedDeck(products: voiced, tier: .onDevice)
    }
}

/// A deterministic ``RefinementInterpreter`` for tests: it ignores the text and always returns a
/// scripted directive on the on-device tier, so `AppModel`'s rework path can be exercised without
/// a model (which is unavailable on the sim/CI).
private struct ScriptedRefiner: RefinementInterpreter {
    let directive: RefinementDirective
    init(_ directive: RefinementDirective) { self.directive = directive }

    func interpret(
        _ refinement: String,
        conversation: [String],
        mission: ShoppingTask,
        profile: TasteProfile
    ) async -> InterpretedRefinement {
        InterpretedRefinement(directive: directive, tier: .onDevice)
    }
}

/// A ``RecapWriter`` that returns a *distinct* tag/line on every call, so a test can prove the
/// app reuses a stored recap (rather than regenerating it) when a kit is unchanged on cart re-reach.
@MainActor
private final class CountingRecapWriter: RecapWriter {
    private(set) var calls = 0
    nonisolated func writeRecap(
        goal: String, plan: [String], items: [RecapFact], profile: TasteProfile, recipient: RecipientRef?
    ) async -> WrittenRecap {
        await MainActor.run {
            calls += 1
            return WrittenRecap(tag: "Tag \(calls)", line: "Line \(calls)", tier: .onDevice)
        }
    }
}

/// A ``TasteExtractor`` test double that returns a fixed profile (standing in for a real model
/// "read" of the refinement text), so the save-to-taste extractor path is testable on CI.
private struct StubExtractor: TasteExtractor {
    let result: TasteProfile
    init(_ result: TasteProfile) { self.result = result }
    func extract(from text: String, base: TasteProfile) async -> TasteProfile? { result }
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

/// A deterministic ``TasteExtractor`` double: stamps a "GoalSeeded" marker into the vibe so a test
/// can prove the goal-first onboarding path actually threads the goal through the extractor seam.
private struct MarkerTasteExtractor: TasteExtractor {
    func extract(from text: String, base: TasteProfile) async -> TasteProfile? {
        var seeded = base
        seeded.vibe.append("GoalSeeded")
        return seeded
    }
}

// MARK: - App Entities: onscreen deck control (#41)

/// The App Intents plumbing that exposes the swipe deck to Siri. Live Siri needs a device, but the
/// entity mapping, the ``ProductEntityQuery`` resolution against ``AppModel``, and each intent's
/// `perform()` are all exercisable here. `@Dependency` can't be resolved via
/// `AppDependencyManager` outside the real perform flow (it traps), but the framework lets us set
/// it manually — so each test assigns `.model` before running, exactly as documented.
@MainActor
struct DeckAppIntentTests {

    /// A real mock-backed deck so `deckProducts` / `sessionProduct(id:)` resolve.
    private func loadedModel() async -> AppModel {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.select(SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)
        return model
    }

    @Test("ProductEntity carries the product's display fields")
    func entityMapsFields() {
        let product = SeedData.coffeeProducts[0]
        let entity = ProductEntity(product)
        #expect(entity.id == product.id)
        #expect(entity.name == product.name)
        #expect(entity.shopName == product.shop.name)
        #expect(entity.rationale == product.rationale)
        #expect(entity.symbol == product.symbol)
        #expect(!entity.priceText.isEmpty)
    }

    @Test("The query suggests the visible deck and resolves ids (stale ids drop out)")
    func queryResolvesDeck() async throws {
        let model = await loadedModel()
        var query = ProductEntityQuery()
        query.model = model   // manual dependency injection (see suite note)

        let suggested = try await query.suggestedEntities()
        #expect(suggested.count == model.deckProducts.count)
        #expect(!suggested.isEmpty)

        let firstID = try #require(suggested.first).id
        let resolved = try await query.entities(for: [firstID, "not-a-real-id"])
        #expect(resolved.map(\.id) == [firstID])   // the bogus id is dropped, not faked
    }

    @Test("AddToKit adds the resolved product through the same path as a swipe")
    func addToKitAdds() async throws {
        let model = await loadedModel()
        let target = try #require(model.deckProducts.first)
        #expect(!model.isInKit(target))

        var intent = AddToKitIntent()
        intent.model = model
        intent.product = ProductEntity(target)
        _ = try await intent.perform()

        #expect(model.isInKit(target))                 // kit mutated via AppModel.accept
        #expect(!model.deckProducts.contains { $0.id == target.id })  // advanced off the deck
    }

    @Test("Skip advances past the product without kitting it")
    func skipAdvances() async throws {
        let model = await loadedModel()
        let target = try #require(model.deckProducts.first)

        var intent = SkipProductIntent()
        intent.model = model
        intent.product = ProductEntity(target)
        _ = try await intent.perform()

        #expect(!model.isInKit(target))
        #expect(!model.deckProducts.contains { $0.id == target.id })
    }

    @Test("A stale product id fails honestly instead of mutating nothing")
    func staleIdThrows() async throws {
        let model = await loadedModel()
        let before = model.kit.count

        var intent = AddToKitIntent()
        intent.model = model
        intent.product = ProductEntity(SeedData.hikeProducts[0])   // not in the coffee deck
        await #expect(throws: DeckIntentError.self) {
            _ = try await intent.perform()
        }
        #expect(model.kit.count == before)
    }

    @Test("ExplainPick answers from the entity's own rationale (even off-deck)")
    func explainPickSucceeds() async throws {
        var intent = ExplainPickIntent()
        intent.product = ProductEntity(SeedData.coffeeProducts[0])
        _ = try await intent.perform()   // returns dialog + snippet without throwing
    }
}
