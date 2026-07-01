import Testing
import Foundation
@testable import CrumbKit

/// The **golden mission set** — a fixed, offline measurement of the deterministic curation pipeline
/// (`RuleBasedMissionPlanner` → `DeterministicMissionOrchestrator` → `RuleBasedRelevanceGate` →
/// `RuleBasedCurator`) run against the seed catalog via ``MockUCPClient``. It locks the *shape* the
/// app degrades to when no model tier is up (plan size, candidate pool, gate keep-rate, deck size,
/// tier), so a change that regresses the deterministic baseline is caught here instead of in a live
/// sim run.
///
/// Scope note: the on-device / private-cloud tiers need `FoundationModels`, which isn't available on
/// the test host, so every tier below is `.ruleBased`. In particular the deterministic planner emits
/// a **single-part** plan for *any* goal — the "3 to 6 parts" decomposition is model-only. That's the
/// baseline Phase 3 will change (adding a single-item altitude flag); this suite documents today's.
@Suite("Golden mission set")
struct GoldenMissionTests {

    // MARK: - Planner golden (goal → plan shape, catalog-independent)

    /// A goal and the deterministic plan shape it must produce. `parts == 1` for every shoppable goal
    /// offline (the floor never decomposes); a non-shoppable goal declines with no task.
    struct PlanCase {
        let goal: String
        let shoppable: Bool
    }

    static let planCases: [PlanCase] = [
        .init(goal: "buy premium jasmine tea", shoppable: true),      // narrow, single item
        .init(goal: "set up my pour-over corner", shoppable: true),   // broad, multi-part *intent*
        .init(goal: "pack me for a rainy weekend hike", shoppable: true),
        .init(goal: "gooseneck kettle", shoppable: true),
        .init(goal: "ab", shoppable: false),                          // too short
        .init(goal: "what should I buy?", shoppable: false),          // a bare question
    ]

    @Test("Deterministic planner: shoppable goals yield a single-part plan; non-shoppable decline")
    func plannerShapes() async {
        let planner = RuleBasedMissionPlanner()
        for c in Self.planCases {
            let planned = await planner.plan(goal: c.goal, profile: SeedData.defaultTasteProfile)
            #expect((planned.task != nil) == c.shoppable, "shoppable mismatch for \(c.goal)")
            if let task = planned.task {
                #expect(task.plan.count == 1, "offline plan should be single-part for \(c.goal)")
                #expect(task.searchQueries == [RuleBasedMissionPlanner.clean(query: c.goal)])
                #expect(planned.tier == .ruleBased(nil))
            } else {
                #expect(planned.decline != nil, "a decline needs a message for \(c.goal)")
            }
        }
    }

    // MARK: - Pipeline golden (seed mission → deck, via the mock catalog)

    /// A whole deterministic pipeline run, keeping the counts a measurement cares about.
    struct Outcome: Equatable {
        var unionCount: Int   // candidates gathered before curation (post-gate, as the app sees them)
        var deckSize: Int     // curated deck size (curator ranks/voices, never drops)
        var tierIsRule: Bool
    }

    /// Drives orchestrator (which runs search + gate) → curator for a seed `mission`, exactly as
    /// ``AppModel/loadCandidates(for:)`` does, on the mock catalog at the app's real floor.
    func runPipeline(_ mission: ShoppingTask, floor: Int = 8) async -> Outcome {
        let gathered = await DeterministicMissionOrchestrator()
            .gather(for: mission, floor: floor, using: MockUCPClient(), gate: RuleBasedRelevanceGate())
        let pool = gathered?.products ?? []
        let deck = await RuleBasedCurator().curate(pool, for: SeedData.defaultTasteProfile, mission: mission)
        return Outcome(unionCount: pool.count, deckSize: deck.products.count, tierIsRule: deck.tier == .ruleBased(nil))
    }

    @Test("Each seed mission resolves to its full curated deck, kept intact through gate + curator")
    func seedMissionsResolveToTheirDecks() async {
        // The mock collapses every one of a mission's queries back to its curated candidate set, and
        // the seed decks (5–6 items) sit below the floor, so the gate passes them through untouched.
        let expected: [(ShoppingTask, Int)] = [
            (SeedData.hike, SeedData.hikeProducts.count),
            (SeedData.coffee, SeedData.coffeeProducts.count),
            (SeedData.desk, SeedData.deskProducts.count),
        ]
        for (mission, deckSize) in expected {
            let out = await runPipeline(mission)
            #expect(out.unionCount == deckSize, "candidate pool for \(mission.id)")
            #expect(out.deckSize == deckSize, "curator never drops for \(mission.id)")
            #expect(out.tierIsRule, "deterministic tier for \(mission.id)")
        }
    }

    // MARK: - Gate discrimination golden (the gate actually filters, not just passes through)

    @Test("The relevance gate drops off-topic items when the on-topic set already clears the floor")
    func gateDropsOffTopic() async {
        // A mixed pool: the coffee deck plus the whole hike deck, judged against the coffee mission.
        // With a floor of 1 the on-topic coffee items already clear it, so the off-topic hike items
        // are dropped — a keep-rate strictly below 100%, proving the gate discriminates.
        let mixed = SeedData.coffeeProducts + SeedData.hikeProducts
        let kept = await RuleBasedRelevanceGate().filter(mixed, for: SeedData.coffee, floor: 1)
        #expect(kept.count == SeedData.coffeeProducts.count, "gate should keep exactly the coffee items")
        #expect(kept.count < mixed.count, "gate must drop the off-topic hike items")
        let keptIDs = Set(kept.map(\.id))
        #expect(SeedData.hikeProducts.allSatisfy { !keptIDs.contains($0.id) }, "no hike item survives")
    }

    // MARK: - Out-of-catalog golden (empty-but-successful, not a crash)

    @Test("A goal with no catalog coverage yields an empty deck, not a failure")
    func outOfCatalogGoalIsEmptyDeck() async throws {
        // "jasmine tea" has no seed products (the live broker has tea; the mock does not). The
        // planner still produces a task; the gather succeeds with an empty union; the deck is empty.
        let planned = await RuleBasedMissionPlanner().plan(goal: "buy premium jasmine tea", profile: SeedData.defaultTasteProfile)
        let task = try #require(planned.task)
        let out = await runPipeline(task)
        #expect(out.unionCount == 0, "the mock has no jasmine tea")
        #expect(out.deckSize == 0)
        #expect(out.tierIsRule)
    }
}
