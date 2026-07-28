import Testing
import Foundation
@testable import CrumbKit

/// The delegation selector: what Crumb may keep without being asked, and — more importantly — what
/// it must leave alone.
@Suite("MissionAutoKeep")
struct MissionAutoKeepTests {

    private func product(_ id: String, _ name: String, price: Decimal = 50) -> Product {
        Product(
            id: id, name: name, shop: Shop(id: "s", name: "Shop"), price: price,
            rating: 0, reviews: 0, rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: price, checkoutURL: nil)]
        )
    }

    private let plan = ["Lacrosse stick", "Gloves", "Helmet", "Cleats"]

    /// One card per part, plus a second stick — the shape a real settled deck has, because the deck
    /// is one globally fit-ranked union with no per-part interleaving.
    private var deck: [Product] {
        [
            product("s1", "STX Stallion Complete Lacrosse Stick"),
            product("s2", "Bravo Elite Lacrosse Stick"),
            product("g1", "Maverik Gloves"),
            product("h1", "Cascade Helmet"),
            product("c1", "New Balance Cleats"),
        ]
    }

    // MARK: What it keeps

    @Test("One keep per uncovered part — a second card for a covered part is passed over, not stopped at")
    func keepsOnePerUncoveredPart() {
        // The failure this pins: an earlier design stopped the pass at the first card that advanced
        // nothing, which on this very deck is card two — collapsing four questions into three.
        let selection = MissionAutoKeep.selection(plan: plan, kit: [], deck: deck, band: nil)
        #expect(selection.kept.map(\.product.id) == ["s1", "g1", "h1", "c1"])
        #expect(selection.kept.map(\.part) == ["Lacrosse stick", "Gloves", "Helmet", "Cleats"])
        #expect(selection.heldBack.isEmpty)
        #expect(selection.heldBackReason == nil)
    }

    @Test("A part the kit already covers is not bought twice")
    func skipsPartsTheKitAlreadyCovers() {
        let kit = [product("owned", "My Old Cascade Helmet")]
        let selection = MissionAutoKeep.selection(plan: plan, kit: kit, deck: deck, band: nil)
        #expect(selection.kept.map(\.product.id) == ["s1", "g1", "c1"])
    }

    @Test("Nothing left uncovered means nothing kept")
    func coveredChecklistKeepsNothing() {
        let kit = [
            product("k1", "Lacrosse Stick"), product("k2", "Gloves"),
            product("k3", "Helmet"), product("k4", "Cleats"),
        ]
        #expect(MissionAutoKeep.selection(plan: plan, kit: kit, deck: deck, band: nil).isEmpty)
    }

    // MARK: What it refuses

    @Test("Delegation stays out of a mission with no checklist to divide")
    func singlePartMissionKeepsNothing() {
        // The one-part shortlist mission is precisely the one whose point is that you look at each
        // candidate; auto has nothing to offer it.
        let selection = MissionAutoKeep.selection(
            plan: ["Premium jasmine tea"], kit: [],
            deck: [product("t1", "Jasmine Pearls Tea")], band: nil
        )
        #expect(selection.isEmpty)
    }

    @Test("A mispriced outlier is handed back, and the part it would have covered stays open")
    func refusesPriceOutliers() {
        // The $1,450-tea shape: one absurd price against a sane norm. Auto must not keep it — and
        // must not end the run on it either, or the person loses the part entirely.
        let priced = [
            product("h9", "Gold-Plated Helmet", price: 4_000),
            product("s1", "STX Stallion Complete Lacrosse Stick", price: 60),
            product("g1", "Maverik Gloves", price: 40),
            product("h1", "Cascade Helmet", price: 80),
            product("c1", "New Balance Cleats", price: 55),
        ]
        let band = PriceBand.from(priced)
        #expect(band != nil)
        let selection = MissionAutoKeep.selection(plan: plan, kit: [], deck: priced, band: band)
        #expect(!selection.kept.contains { $0.product.id == "h9" })
        #expect(selection.heldBack.map(\.product.id) == ["h9"])
        #expect(selection.heldBackReason != nil)
        // The refusal did not cost the person their helmet.
        #expect(selection.kept.map(\.product.id) == ["s1", "g1", "h1", "c1"])
    }

    @Test("A refusal with nothing kept alongside it is not reported at all")
    func lonelyRefusalIsSilent() {
        // Nothing was delegated, so there is nothing to explain — the person is about to be asked
        // about that very card in the ordinary way.
        let priced = [
            product("h9", "Gold-Plated Helmet", price: 4_000),
            product("x1", "Water Bottle", price: 20), product("x2", "Towel", price: 20),
            product("x3", "Sock", price: 20), product("x4", "Wristband", price: 20),
        ]
        let selection = MissionAutoKeep.selection(
            plan: ["Helmet", "Gloves"], kit: [], deck: priced, band: PriceBand.from(priced)
        )
        #expect(selection.isEmpty)
        #expect(selection.heldBack.isEmpty)
    }

    @Test("Crumb's own prose about a product can never make it cover a part")
    func rationaleIsNotEvidence() {
        // The deterministic curator — the floor on every no-model device — voices every card as
        // `A steady pick for "<mission title>"`. On a goal that names its own parts, that sentence
        // contains every head noun in the checklist, so reading it as evidence would let a pair of
        // cleats "cover" Helmet and be filed under Lacrosse stick in the receipt.
        let title = "Lacrosse gear — stick, helmet and gloves for my son"
        let cleats = Product(
            id: "c1", name: "Speedturf Cleats", shop: Shop(id: "s", name: "Shop"), price: 50,
            rating: 0, reviews: 0, rationale: "A steady pick for “\(title)”.", symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "c1.v", title: "Standard", price: 50, checkoutURL: nil)]
        )
        let checklist = ["Lacrosse stick", "Helmet", "Gloves", "Cleats"]
        let selection = MissionAutoKeep.selection(plan: checklist, kit: [], deck: [cleats], band: nil)
        #expect(selection.kept.map(\.part) == ["Cleats"])
    }

    @Test("An empty deck is a no-op, not a crash")
    func emptyDeckKeepsNothing() {
        #expect(MissionAutoKeep.selection(plan: plan, kit: [], deck: [], band: nil).isEmpty)
    }

    @Test("Below PriceBand's sample size there is no band, and auto still runs")
    func noBandStillRuns() {
        // Three priced items have no reliable middle to be an outlier against, and nothing auto does
        // is irreversible — the cart and every checkout remain a human tap.
        let small = [product("s1", "Lacrosse Stick"), product("g1", "Gloves")]
        let selection = MissionAutoKeep.selection(
            plan: plan, kit: [], deck: small, band: PriceBand.from(small)
        )
        #expect(selection.kept.map(\.product.id) == ["s1", "g1"])
    }
}
