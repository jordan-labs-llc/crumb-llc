import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the mission orchestrator (PR 3). The agentic tool loop stays
/// untested (unavailable on CI/sim, like every model path) — but the shared search fan-out, the
/// deterministic gather floor, the candidate collector, and the pure tool cores are exercised here,
/// so the mandatory floor and the tool logic are proven with no model.
@Suite("MissionOrchestrator")
struct MissionOrchestratorTests {

    // MARK: Doubles

    private let shop = Shop(id: "shop", name: "Shop")

    private func product(_ id: String, _ name: String) -> Product {
        Product(
            id: id, name: name, shop: shop, price: 50, rating: 0, reviews: 0,
            rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: 50, checkoutURL: nil)]
        )
    }

    /// Returns preset products per query; a query in `failing` throws (to model an outage).
    private struct StubUCP: UCPClient {
        var results: [String: [Product]] = [:]
        var failing: Set<String> = []
        func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product] {
            if failing.contains(query) { throw UCPError.emptyShopHandoff("fail") }
            return results[query] ?? []
        }
        func product(id: Product.ID) async throws -> Product { throw UCPError.productNotFound(id) }
        func assembleCart(_ items: [KitItem]) async throws -> Cart { throw UCPError.emptyShopHandoff("x") }
        func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL { throw UCPError.emptyShopHandoff(shop.id) }
    }

    private func mission(queries: [String], plan: [String] = []) -> ShoppingTask {
        ShoppingTask(
            id: "goal", title: "Mission", subtitle: "sub", plan: plan, curatorNote: "",
            accentHex: 0, candidateIDs: [], searchQueries: queries
        )
    }

    // MARK: searchUnion

    @Test("searchUnion dedupes the union across queries by id")
    func searchUnionDedupes() async {
        let ucp = StubUCP(results: [
            "a": [product("1", "One"), product("2", "Two")],
            "b": [product("2", "Two"), product("3", "Three")],
        ])
        let union = await ucp.searchUnion(["a", "b"])
        #expect(union?.map(\.id) == ["1", "2", "3"])
    }

    @Test("searchUnion returns nil only when every query errors")
    func searchUnionOutage() async {
        let ucp = StubUCP(results: ["a": [product("1", "One")]], failing: ["a", "b"])
        #expect(await ucp.searchUnion(["a", "b"]) == nil)
        // A partial failure still returns the survivors.
        let partial = StubUCP(results: ["a": [product("1", "One")]], failing: ["b"])
        #expect(await partial.searchUnion(["a", "b"])?.map(\.id) == ["1"])
    }

    // MARK: DeterministicMissionOrchestrator

    @Test("Deterministic gather searches the mission's queries and gates off-topic items")
    func deterministicGather() async {
        let ucp = StubUCP(results: [
            "lacrosse stick": [product("s1", "Lacrosse stick"), product("x1", "Rowing shirt")],
        ])
        let m = mission(queries: ["lacrosse stick"], plan: ["Lacrosse stick"])
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: m, floor: 1, using: ucp, gate: RuleBasedRelevanceGate()
        )
        #expect(gathered?.usedAgent == false)
        // The rowing shirt shares no keyword with the lacrosse mission → dropped by the gate.
        #expect(gathered?.products.map(\.id) == ["s1"])
    }

    @Test("Deterministic gather returns nil on a total outage")
    func deterministicOutage() async {
        let ucp = StubUCP(results: [:], failing: ["q"])
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: mission(queries: ["q"]), floor: 8, using: ucp, gate: RuleBasedRelevanceGate()
        )
        #expect(gathered == nil)
    }

    // MARK: CandidateCollector

    @Test("Collector dedupes by id and preserves discovery order")
    func collectorDedupes() async {
        let collector = CandidateCollector()
        await collector.add([product("1", "One"), product("2", "Two")])
        await collector.add([product("2", "Two"), product("3", "Three")])
        #expect(await collector.products.map(\.id) == ["1", "2", "3"])
        #expect(await collector.count == 3)
    }

    @Test("Collector caps the pool")
    func collectorCaps() async {
        let collector = CandidateCollector(cap: 2)
        await collector.add([product("1", "a"), product("2", "b"), product("3", "c")])
        #expect(await collector.products.map(\.id) == ["1", "2"])
    }

    @Test("Collector streams each newly-inserted batch once on `picks`, then finishes")
    func collectorStreams() async {
        let collector = CandidateCollector()
        // Subscribe before adding so no batch is missed.
        let consumer = Task {
            var batches: [[String]] = []
            for await batch in collector.picks { batches.append(batch.map(\.id)) }
            return batches
        }
        await collector.add([product("1", "One"), product("2", "Two")])
        await collector.add([product("2", "Two"), product("3", "Three")])   // "2" is a dup — not re-yielded
        await collector.finish()
        let batches = await consumer.value
        #expect(batches == [["1", "2"], ["3"]])   // first batch both; second only the fresh id
    }

    @Test("Deterministic gather streams raw picks through the collector as it searches")
    func deterministicGatherStreams() async {
        // Short (≤2-char) queries make the gate keyword set empty → pass-through, so the terminal
        // pool is the raw union and the test isolates the *streaming*, not the gate.
        let ucp = StubUCP(results: [
            "aa": [product("s1", "One")],
            "bb": [product("s2", "Two")],
        ])
        let collector = CandidateCollector()
        let consumer = Task {
            var ids: [String] = []
            for await batch in collector.picks { ids.append(contentsOf: batch.map(\.id)) }
            return ids
        }
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: mission(queries: ["aa", "bb"]), floor: 1, using: ucp, gate: RuleBasedRelevanceGate(), into: collector
        )
        await collector.finish()
        let streamed = await consumer.value
        // Order isn't guaranteed across concurrent queries, so compare as sets.
        #expect(Set(streamed) == ["s1", "s2"])                       // both raw picks streamed
        #expect(Set(gathered?.products.map(\.id) ?? []) == ["s1", "s2"])   // and returned in the terminal pool
    }

    // MARK: GatherToolSupport

    @Test("onTopic keeps mission-matching products and drops the off-topic")
    func onTopicGuard() {
        let m = mission(queries: ["lacrosse stick"], plan: ["Lacrosse stick"])
        let kept = GatherToolSupport.onTopic(
            [product("s1", "Lacrosse stick"), product("x1", "Rowing shirt")], for: m
        )
        #expect(kept.map(\.id) == ["s1"])
    }

    @Test("summary reports counts and off-topic drops, or a not-found note")
    func summaryText() {
        let found = GatherToolSupport.summary(kept: [product("1", "Kettle")], dropped: 2)
        #expect(found.contains("Found 1 on-topic"))
        #expect(found.contains("Dropped 2 off-topic"))
        #expect(GatherToolSupport.summary(kept: [], dropped: 0).contains("No products found"))
        #expect(GatherToolSupport.summary(kept: [], dropped: 3).contains("dropped 3 off-topic"))
    }

    // MARK: AppleFoundationMissionOrchestrator pure helpers

    @Test("mergeDedup keeps the primary order then appends new-by-id from secondary")
    func mergeDedup() {
        let merged = AppleFoundationMissionOrchestrator.mergeDedup(
            [product("1", "a"), product("2", "b")],
            [product("2", "b"), product("3", "c")]
        )
        #expect(merged.map(\.id) == ["1", "2", "3"])
    }

    @Test("Orchestrator instructions brief + guide describe the mission and the tool loop")
    func instructionsContent() {
        let m = mission(queries: ["gooseneck kettle"], plan: ["Kettle", "Grinder"])
        let brief = OrchestratorInstructions.missionBrief(for: m)
        #expect(brief.contains("\"Mission\""))
        #expect(brief.contains("Kettle, Grinder"))
        #expect(OrchestratorInstructions.guide.contains("search_catalog"))
        #expect(OrchestratorInstructions.guide.contains("find_similar"))
    }
}
