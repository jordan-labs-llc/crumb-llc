import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the relevance gate. The optional model pass stays
/// untested (unavailable on CI/sim, exactly like the curator/planner) — but the pure keyword
/// match, the never-empty floor, and the drop-under-floor refusal are exercised exhaustively.
@Suite("RelevanceGate")
struct RelevanceGateTests {

    // MARK: Helpers

    private let shop = Shop(id: "shop", name: "Shop")

    private func product(_ id: String, _ name: String, desc: String = "") -> Product {
        Product(
            id: id, name: name, shop: shop, price: 50, rating: 0, reviews: 0,
            rationale: desc, symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: 50, checkoutURL: nil)]
        )
    }

    /// A lacrosse mission (what the failing live test was about), with clean multi-part queries.
    private let lacrosse = ShoppingTask(
        id: "goal.lacrosse",
        title: "Zephyr's midfield lacrosse kit",
        subtitle: "Mercer Lacrosse Club · 2026-2027 season",
        plan: ["Lacrosse stick", "Gloves", "Shoulder pads", "Helmet", "Cleats", "Gear bag"],
        curatorNote: "",
        accentHex: 0x1C4B43,
        candidateIDs: [],
        searchQueries: ["lacrosse stick", "lacrosse gloves", "shoulder pads", "lacrosse helmet", "lacrosse cleats", "lacrosse gear bag"]
    )

    // MARK: Keyword extraction

    @Test("Keywords pull significant words from queries + plan + title, dropping stopwords")
    func keywords() {
        let kw = RuleBasedRelevanceGate.keywords(for: lacrosse)
        #expect(kw.contains("lacrosse"))
        #expect(kw.contains("gloves"))
        #expect(kw.contains("helmet"))
        #expect(kw.contains("cleats"))
        // Stopwords / short tokens never become keywords.
        #expect(!kw.contains("for"))
        #expect(!kw.contains("the"))
    }

    // MARK: The drop (the whole point)

    @Test("Drops a clearly off-topic item (a rowing shirt) from a lacrosse deck")
    func dropsOffTopic() {
        var deck = (1...10).map { product("lax.\($0)", "Lacrosse item \($0)", desc: "lacrosse gear") }
        // The real bug: a rowing shirt that decoded from a live search.
        let rower = product("row.1", "Men's Zephyr — Royal Air Force June 2026 Kit Shop",
                            desc: "Lightweight rowing training top for the RAF boat club.")
        deck.append(rower)

        let kept = RuleBasedRelevanceGate.keep(deck, matching: RuleBasedRelevanceGate.keywords(for: lacrosse), floor: 8)
        #expect(!kept.contains { $0.id == "row.1" })           // the rower is dropped
        #expect(kept.count == 10)                               // every on-topic item survives
    }

    @Test("isRelevant matches on name OR merchant description")
    func isRelevant() {
        let kw = RuleBasedRelevanceGate.keywords(for: lacrosse)
        // Matches on description even with a brand-only name.
        #expect(RuleBasedRelevanceGate.isRelevant(product("p", "ProGrip 9000", desc: "Padded lacrosse gloves"), keywords: kw))
        // No shared word → off-topic.
        #expect(!RuleBasedRelevanceGate.isRelevant(product("p", "Ceramic Pour-Over Dripper", desc: "Holds heat for coffee."), keywords: kw))
    }

    // MARK: The never-empty floor

    @Test("Never returns fewer than the floor: too few matches top up from the remainder")
    func floorTopsUp() {
        // Only 2 of 12 match; floor is 8 → keep the 2 relevant + 6 filler = 8, never fewer.
        var deck = (1...10).map { product("off.\($0)", "Unrelated gadget \($0)", desc: "kitchen widget") }
        deck.insert(product("lax.1", "Lacrosse stick", desc: ""), at: 0)
        deck.insert(product("lax.2", "Lacrosse helmet", desc: ""), at: 1)

        let kept = RuleBasedRelevanceGate.keep(deck, matching: RuleBasedRelevanceGate.keywords(for: lacrosse), floor: 8)
        #expect(kept.count == 8)
        // The relevant ones are always kept, and lead.
        #expect(kept.prefix(2).map(\.id) == ["lax.1", "lax.2"])
    }

    @Test("A deck at or below the floor passes through untouched (the mock/seed path)")
    func smallDeckPassesThrough() {
        let deck = (1...5).map { product("x.\($0)", "Random \($0)", desc: "nothing relevant") }
        let kept = RuleBasedRelevanceGate.keep(deck, matching: RuleBasedRelevanceGate.keywords(for: lacrosse), floor: 8)
        #expect(kept.count == 5)                                // never drops below what we have
    }

    @Test("No keywords → everything passes through")
    func noKeywordsPassThrough() {
        let deck = (1...4).map { product("x.\($0)", "Thing \($0)") }
        let kept = RuleBasedRelevanceGate.keep(deck, matching: [], floor: 8)
        #expect(kept.count == 4)
    }

    // MARK: Seed regression — seed products are all relevant to their seed mission

    @Test("Every seed product survives its own seed mission's gate (no regression)")
    func seedDecksNeverRegress() {
        let cases: [(ShoppingTask, [Product])] = [
            (SeedData.hike, SeedData.hikeProducts),
            (SeedData.coffee, SeedData.coffeeProducts),
            (SeedData.desk, SeedData.deskProducts),
        ]
        for (mission, products) in cases {
            // floor: 1 forces the *keyword match* to carry the weight (no floor top-up masking a
            // dropped seed product). All must still survive.
            let kept = RuleBasedRelevanceGate.keep(products, matching: RuleBasedRelevanceGate.keywords(for: mission), floor: 1)
            #expect(kept.count == products.count, "seed mission \(mission.id) dropped a product")
            #expect(Set(kept.map(\.id)) == Set(products.map(\.id)))
        }
    }

    // MARK: applyDrops — the model path's floor guard

    @Test("applyDrops removes the named IDs when the floor still holds")
    func applyDropsRemoves() {
        let deck = (1...12).map { product("p.\($0)", "Item \($0)") }
        let kept = AppleFoundationRelevanceGate.applyDrops(["p.3", "p.7"], to: deck, floor: 8)
        #expect(kept.count == 10)
        #expect(!kept.contains { $0.id == "p.3" || $0.id == "p.7" })
    }

    @Test("applyDrops refuses a drop that would strand the deck below the floor")
    func applyDropsRefusesBelowFloor() {
        let deck = (1...9).map { product("p.\($0)", "Item \($0)") }
        // Dropping 3 would leave 6 < floor 8 → refuse, keep all 9.
        let kept = AppleFoundationRelevanceGate.applyDrops(["p.1", "p.2", "p.3"], to: deck, floor: 8)
        #expect(kept.count == 9)
    }

    @Test("applyDrops with no IDs is a no-op")
    func applyDropsEmpty() {
        let deck = (1...3).map { product("p.\($0)", "Item \($0)") }
        #expect(AppleFoundationRelevanceGate.applyDrops([], to: deck, floor: 8).count == 3)
    }
}
