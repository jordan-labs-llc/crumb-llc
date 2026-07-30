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

    @Test("searchUnionByQuery names the earliest query that returned each product")
    func searchUnionKeepsProvenance() async {
        let ucp = StubUCP(results: [
            "a": [product("1", "One"), product("2", "Two")],
            "b": [product("2", "Two"), product("3", "Three")],
        ])
        let union = await ucp.searchUnionByQuery(["a", "b"])
        #expect(union?.products.map(\.id) == ["1", "2", "3"])
        #expect(union?.parts == ["1": "a", "2": "a", "3": "b"])
        // Same outage contract as the plain union.
        #expect(await StubUCP(results: [:], failing: ["a"]).searchUnionByQuery(["a"]) == nil)
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

    @Test("Collector records which search found each product")
    func collectorAttributes() async {
        let collector = CandidateCollector()
        await collector.add([product("1", "Kettle")], from: GatherOrigin(part: "Kettle", rank: 0))
        await collector.add([product("2", "Mat")], from: GatherOrigin(part: "Mat", rank: 1))
        await collector.add([product("3", "Lamp")])   // an unnamed search claims nothing
        #expect(await collector.attribution == ["1": "Kettle", "2": "Mat"])
    }

    /// The mission's queries fan out in parallel, so a product two of them return would otherwise be
    /// attributed to whichever search happened to come back first. The lower rank always wins.
    @Test("A better-ranked search takes over a product an improvised one already claimed")
    func collectorPrefersTheBetterRankedClaim() async {
        let collector = CandidateCollector()
        await collector.add(
            [product("1", "Kettle")], from: GatherOrigin(part: "gooseneck", rank: GatherOrigin.improvised)
        )
        await collector.add([product("1", "Kettle")], from: GatherOrigin(part: "Kettle", rank: 0))
        #expect(await collector.attribution == ["1": "Kettle"])
        // …and a worse-ranked latecomer cannot take it back.
        await collector.add([product("1", "Kettle")], from: GatherOrigin(part: "Mat", rank: 3))
        #expect(await collector.attribution == ["1": "Kettle"])
        #expect(await collector.products.map(\.id) == ["1"], "attribution never re-pools a duplicate")
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

    @Test("Deterministic gather gates each batch before it enters the shared collector")
    func deterministicGatherGatesStream() async {
        let ucp = StubUCP(results: [
            "lacrosse stick": [product("s1", "Lacrosse stick"), product("x1", "Rowing shirt")],
        ])
        let m = mission(queries: ["lacrosse stick"], plan: ["Lacrosse stick"])
        let collector = CandidateCollector()
        let consumer = Task {
            var ids: [String] = []
            for await batch in collector.picks { ids.append(contentsOf: batch.map(\.id)) }
            return ids
        }
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: m, floor: 1, using: ucp, gate: RuleBasedRelevanceGate(), into: collector
        )
        await collector.finish()
        // The off-topic rowing shirt must never stream or pool — the collector snapshot is what the
        // safety net settles on when the watchdog launches this floor, so a raw add here would put
        // ungated items in the deck.
        #expect(await consumer.value == ["s1"])
        #expect(await collector.products.map(\.id) == ["s1"])
        #expect(gathered?.products.map(\.id) == ["s1"])
    }

    @Test("Floor top-up items (kept only to meet the floor) still stream through the collector")
    func deterministicGatherStreamsTopUp() async {
        // Nothing matches the mission keywords, so the gate's floor top-up is the whole terminal
        // pool. Those items are dropped at the batch gate, so the gather must add them at return —
        // the settle keeps only cards that streamed and would otherwise silently drop them.
        let ucp = StubUCP(results: [
            "lacrosse stick": [product("x1", "Rowing shirt"), product("x2", "Canoe paddle")],
        ])
        let m = mission(queries: ["lacrosse stick"], plan: ["Lacrosse stick"])
        let collector = CandidateCollector()
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: m, floor: 2, using: ucp, gate: RuleBasedRelevanceGate(), into: collector
        )
        #expect(gathered?.products.map(\.id) == ["x1", "x2"])
        #expect(await collector.products.map(\.id) == ["x1", "x2"])
    }

    // MARK: Watchdog path (safety net + deterministic floor, shared collector)

    @Test("A watchdog-launched floor cannot leak ungated results into the settled pool")
    func watchdogFloorIsGated() async {
        // Reproduces the settle-path gate bypass: a stalled model turn trips the watchdog, which
        // launches the deterministic floor into the SHARED collector; the net then converges on the
        // collector snapshot, not the floor's gated return. If the floor added raw batches (the old
        // behavior), the off-topic rowing shirt reached the settled deck unfiltered.
        let ucp = StubUCP(results: [
            "lacrosse stick": [product("s1", "Lacrosse stick"), product("x1", "Rowing shirt")],
        ])
        let m = mission(queries: ["lacrosse stick"], plan: ["Lacrosse stick"])
        let collector = CandidateCollector()
        let gate = RuleBasedRelevanceGate()
        let net = GatherSafetyNet(watchdogSeconds: 0.05, deadlineSeconds: 5.0)
        let result = await net.run(
            floor: 1,
            turn: { try? await Task.sleep(for: .milliseconds(300)) },   // empty, ends after watchdog
            poolSnapshot: { await collector.products },
            floorGather: {
                await DeterministicMissionOrchestrator().gather(
                    for: m, floor: 1, using: ucp, gate: gate, into: collector
                )
            }
        )
        #expect(result?.products.map(\.id) == ["s1"])                  // gated even on this path
        #expect(await collector.products.map(\.id) == ["s1"])          // and never streamed raw
        #expect(result?.usedAgent == false)
    }

    @Test("Deterministic gather attributes each find to the plan part its query was for")
    func deterministicGatherAttributes() async {
        let ucp = StubUCP(results: [
            "gooseneck kettle": [product("k1", "Heron Kettle")],
            "linen brew mat": [product("m1", "Linen Mat")],
        ])
        let m = mission(
            queries: ["gooseneck kettle", "linen brew mat"], plan: ["Gooseneck kettle", "A tidy mat"]
        )
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: m, floor: 1, using: ucp, gate: RuleBasedRelevanceGate()
        )
        // The plan's label, not the raw query — it is the phrase the person read and could edit.
        #expect(gathered?.parts == ["k1": "Gooseneck kettle", "m1": "A tidy mat"])
    }

    @Test("A floor top-up is attributed to the search that actually returned it")
    func topUpKeepsItsAttribution() async {
        // Nothing matches the mission keywords, so both survive only as the gate's floor top-up —
        // dropped at the batch gate and added at return, where they must still name their search.
        let ucp = StubUCP(results: [
            "gooseneck kettle": [product("x1", "Rowing shirt")],
            "linen brew mat": [product("x2", "Canoe paddle")],
        ])
        let m = mission(
            queries: ["gooseneck kettle", "linen brew mat"], plan: ["Gooseneck kettle", "A tidy mat"]
        )
        let gathered = await DeterministicMissionOrchestrator().gather(
            for: m, floor: 2, using: ucp, gate: RuleBasedRelevanceGate()
        )
        #expect(gathered?.parts == ["x1": "Gooseneck kettle", "x2": "A tidy mat"])
    }

    // MARK: GatherToolSupport

    @Test("A tool's query is attributed to the plan part it was asked to search")
    func toolOriginNamesThePlanPart() {
        let m = mission(queries: ["gooseneck kettle", "burr grinder"], plan: ["Kettle", "Grinder"])
        #expect(GatherToolSupport.origin(for: "Gooseneck Kettle", in: m) == GatherOrigin(part: "Kettle", rank: 0))
        // A search the model reached for beyond the plan becomes its own, improvised part.
        let improvised = GatherToolSupport.origin(for: "desk lamp", in: m)
        #expect(improvised == GatherOrigin(part: "desk lamp", rank: GatherOrigin.improvised))
    }

    @Test("A plan and queries that don't line up fall back to naming the query")
    func partLabelFallsBackWhenPlanAndQueriesDesync() {
        // A part whose query cleans away to nothing is dropped from the queries alone; pairing by
        // position through that gap would file every later part's finds under its neighbour.
        let m = mission(queries: ["gooseneck kettle"], plan: ["Kettle", "Grinder"])
        #expect(GatherToolSupport.partLabel(at: 0, in: m) == "gooseneck kettle")
    }

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
