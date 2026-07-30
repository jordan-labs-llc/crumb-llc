import Testing
import Foundation
@testable import CrumbKit

/// What tells an alternative from a different part of the same errand.
///
/// The reported failure this answers: a pour-over kit's deck is one union of five searches, so read
/// flat it offers the brew mat as the cheaper option beside the beans. Both signals here exist
/// because either alone gets that wrong somewhere — the plan's words can't place a product nobody
/// listed, and provenance collapses whenever one search answers for several parts.
@Suite("Mission part attribution")
struct MissionPartAttributionTests {

    private let shop = Shop(id: "shop", name: "Shop")

    private func product(_ id: String, _ name: String, rationale: String = "") -> Product {
        Product(
            id: id, name: name, shop: shop, price: 50, rating: 0, reviews: 0,
            rationale: rationale, symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: 50, checkoutURL: nil)]
        )
    }

    private let plan = ["Gooseneck kettle", "Burr grinder", "Fresh beans", "A tidy mat"]

    // MARK: The plan's own words

    @Test("A product is placed by the plan part whose head noun it names")
    func placedByHeadNoun() {
        #expect(MissionPartAttribution.part(
            of: product("k", "Heron Gooseneck Kettle"), plan: plan, provenance: nil
        ) == "Gooseneck kettle")
        #expect(MissionPartAttribution.part(
            of: product("m", "Linen Brew Mat"), plan: plan, provenance: nil
        ) == "A tidy mat")
    }

    /// The whole reason the plan is consulted before provenance. Every search against the mock
    /// catalog answers with the mission's entire candidate set, so provenance alone files the mat,
    /// the beans and the kettle under whichever query raced first — and then offers them to each
    /// other as price alternatives.
    @Test("The plan outranks provenance when a search answered for several parts")
    func planBeatsCollapsedProvenance() {
        let mat = MissionPartAttribution.part(
            of: product("m", "Linen Brew Mat"), plan: plan, provenance: "Gooseneck kettle"
        )
        #expect(mat == "A tidy mat")
    }

    // MARK: Provenance

    @Test("A product no plan part names falls back to the search that found it")
    func fallsBackToProvenance() {
        #expect(MissionPartAttribution.part(
            of: product("l", "Anglepoise Desk Lamp"), plan: plan, provenance: "desk lamp"
        ) == "desk lamp")
    }

    @Test("A product neither signal places has no part")
    func unplaceable() {
        #expect(MissionPartAttribution.part(
            of: product("l", "Anglepoise Desk Lamp"), plan: plan, provenance: nil
        ) == nil)
    }

    /// The trap ``KitCompleteness`` documents for auto-keep, and the same answer: the deterministic
    /// curator voices every card as `A steady pick for "<mission title>"`, so a mission whose goal
    /// names its parts would put every head noun on every card.
    @Test("Crumb's own sentence about a product is not evidence of what it is")
    func ignoresRationale() {
        let mat = product("m", "Linen Brew Mat", rationale: "A steady pick for your kettle and beans")
        #expect(MissionPartAttribution.part(of: mat, plan: plan, provenance: nil) == "A tidy mat")
    }

    @Test("An all-stopword plan part never swallows the deck")
    func stopwordPartIsSkipped() {
        #expect(MissionPartAttribution.part(
            of: product("k", "Heron Gooseneck Kettle"), plan: ["and the", "Gooseneck kettle"], provenance: nil
        ) == "Gooseneck kettle")
    }

    // MARK: Peers — the set foils are drawn from

    @Test("Peers are the same part's other candidates, in the order given")
    func peersAreSamePart() {
        let deck = [
            product("k1", "Heron Gooseneck Kettle"),
            product("m1", "Linen Brew Mat"),
            product("k2", "Stagg Pour-Over Kettle"),
            product("b1", "Sunday Roast Beans"),
        ]
        let peers = MissionPartAttribution.peers(
            of: deck[0], among: deck, plan: plan, provenance: [:]
        )
        #expect(peers.map(\.id) == ["k2"], "the mat and the beans are other parts, not alternatives")
    }

    @Test("A candidate nothing can place is offered no peers at all")
    func unplaceableHasNoPeers() {
        let lamp = product("l", "Anglepoise Desk Lamp")
        let deck = [lamp, product("l2", "Ikea Desk Lamp")]
        #expect(MissionPartAttribution.peers(of: lamp, among: deck, plan: plan, provenance: [:]).isEmpty)
        // With provenance both lamps share, they are alternatives after all.
        let placed = MissionPartAttribution.peers(
            of: lamp, among: deck, plan: plan, provenance: ["l": "desk lamp", "l2": "desk lamp"]
        )
        #expect(placed.map(\.id) == ["l2"])
    }

    // MARK: The precondition — attribution has to divide something

    /// The deterministic planner frames almost every typed goal as one part with one query, so on
    /// that path every candidate shares a provenance and the pool "agrees" it is all one part. That
    /// is the absence of evidence, not evidence of comparability.
    @Test("A pool that resolves to one part is not partitioned")
    func onePartPoolIsNotPartitioned() {
        let onePartPlan = ["Set up my pour-over corner"]
        let deck = [
            product("k", "Heron Gooseneck Kettle"),
            product("m", "Linen Brew Mat"),
            product("b", "Sunday Roast Beans"),
        ]
        let provenance = Dictionary(uniqueKeysWithValues: deck.map { ($0.id, "set up my pour over corner") })
        #expect(!MissionPartAttribution.isPartitioned(deck, plan: onePartPlan, provenance: provenance))
        // The same deck under a plan that names its parts *is* divided.
        #expect(MissionPartAttribution.isPartitioned(deck, plan: plan, provenance: provenance))
    }

    @Test("Resolving the whole deck leaves the unplaceable out rather than bucketing them together")
    func partsMapOmitsUnplaceable() {
        let deck = [product("k1", "Heron Gooseneck Kettle"), product("l", "Anglepoise Desk Lamp")]
        let parts = MissionPartAttribution.parts(of: deck, plan: plan, provenance: [:])
        #expect(parts == ["k1": "Gooseneck kettle"])
    }
}
