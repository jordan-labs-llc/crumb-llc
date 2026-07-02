import Testing
import Foundation
@testable import CrumbKit

@Suite("CrumbKit smoke tests")
struct CrumbKitTests {

    @Test("searchCatalog(\"hike\") returns the hike candidates")
    func searchHikeReturnsCandidates() async throws {
        let client = MockUCPClient()
        let results = try await client.searchCatalog("hike", placements: [.organic])

        let expected = SeedData.hike.candidateIDs
        #expect(results.map(\.id) == expected)
        #expect(results.allSatisfy { $0.id.hasPrefix("hike.") })
        #expect(results.count == 6)
    }

    @Test("get_product resolves a known id and throws for an unknown one")
    func productLookup() async throws {
        let client = MockUCPClient()

        let shell = try await client.product(id: "hike.shell")
        #expect(shell.name == "Stormcaught Shell")
        #expect(shell.price == Decimal(228))
        #expect(shell.shop.name == "Northbound Supply")

        await #expect(throws: UCPError.self) {
            _ = try await client.product(id: "does.not.exist")
        }
    }

    @Test("Cart.priceRange spans the cheapest and dearest option; nil when empty (#60)")
    func cartPriceRange() {
        #expect(Cart(items: []).priceRange == nil)

        let product = SeedData.hikeProducts[0]
        let items = [Decimal(31), Decimal(24), Decimal(28)].enumerated().map { index, price in
            KitItem(product: product, variant: Variant(id: "v\(index)", title: "V", price: price))
        }
        let range = Cart(items: items).priceRange
        #expect(range?.min == Decimal(24))
        #expect(range?.max == Decimal(31))

        // A single option collapses to a point range (min == max), so the UI shows one price.
        let single = Cart(items: [items[0]]).priceRange
        #expect(single?.min == single?.max)
    }

    @Test("Cart subtotal and per-shop grouping are correct")
    func cartGrouping() async throws {
        let client = MockUCPClient()
        // Two Northbound items + one Ridgeline item.
        let items = try await [
            client.product(id: "hike.shell"),   // Northbound, 228
            client.product(id: "hike.cap"),     // Northbound, 42
            client.product(id: "hike.pack"),    // Ridgeline, 189
        ].map(KitItem.init(product:))

        let cart = try await client.assembleCart(items)
        #expect(cart.subtotal == Decimal(228 + 42 + 189))
        #expect(cart.shops.count == 2)
        #expect(cart.subtotal(for: SeedData.Shops.northbound) == Decimal(270))

        let handoff = try await client.checkoutHandoff(
            for: SeedData.Shops.northbound, in: cart
        )
        #expect(handoff.host == "checkout.example.invalid")
    }

    @Test("RuleBasedCurator ranks deterministically and keeps all products")
    func curatorRanking() async throws {
        let curator = RuleBasedCurator()
        let profile = SeedData.defaultTasteProfile
        let products = SeedData.hikeProducts

        let first = await curator.rank(products, for: profile)
        let second = await curator.rank(products, for: profile)

        #expect(first.map(\.id) == second.map(\.id))          // deterministic
        #expect(Set(first.map(\.id)) == Set(products.map(\.id))) // nothing dropped
    }

    @Test("curate() default ranks like rank() and rewrites each rationale, no fallback note")
    func curateDefault() async throws {
        let curator = RuleBasedCurator()
        let profile = SeedData.defaultTasteProfile
        let products = SeedData.hikeProducts

        let ranked = await curator.rank(products, for: profile)
        let deck = await curator.curate(products, for: profile, mission: SeedData.hike)

        // Same order as rank(), nothing dropped.
        #expect(deck.products.map(\.id) == ranked.map(\.id))
        // The default engine is a *chosen* default, not a degraded one → no honest note.
        #expect(deck.tier == .ruleBased(nil))
        #expect(deck.tier.fallbackNote == nil)
        // Every card carries the curator's rationale — mission-aware now (#33): the default curate
        // threads the mission through, so the floor voices against *this* mission, not mission-agnostically.
        for product in deck.products {
            #expect(product.rationale == curator.rationale(for: product, profile: profile, recipient: nil, mission: SeedData.hike))
        }
    }

    // MARK: Per-card voice floor (#22 — never echo the raw catalog blurb as the curator's voice)

    /// A live-style product whose `rationale` is the raw merchant blurb (does not echo any leaning).
    private func liveProduct(_ blurb: String) -> Product {
        Product(
            id: "live.p", name: "Jasmine Tea", shop: Shop(id: "s", name: "thefoalyard.co.uk"),
            price: 17, rating: 0, reviews: 0, rationale: blurb, symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "live.p.v", title: "Standard", price: 17, checkoutURL: nil)]
        )
    }

    @Test("A live merchant blurb is reframed into curator voice, not echoed verbatim")
    func liveBlurbReframedWithLeaning() {
        let curator = RuleBasedCurator()
        let blurb = "Premium loose jasmine green tea leaves in a 8.46 oz bag, ideal for hot or cold beverages and boba."
        let product = liveProduct(blurb)
        let profile = TasteProfile(vibe: [], leanings: ["Bright and floral"], budgetComfort: 0.5, signatureLine: "")

        let owner = curator.rationale(for: product, profile: profile)
        #expect(!owner.contains(blurb))                 // the raw blurb is NOT passed off as our voice
        #expect(owner.contains("your lean toward"))     // a real curator line stands in its place

        let mom = RecipientRef(id: "m", name: "Mom", accentHex: 0)
        let gift = curator.rationale(for: product, profile: profile, recipient: mom)
        #expect(!gift.contains(blurb))
        #expect(gift.contains("Mom's lean toward"))
        #expect(!gift.contains("your lean toward"))
    }

    @Test("With no stated leaning a live blurb still isn't echoed — a generic curator line stands in")
    func liveBlurbReframedNoLeaning() {
        let curator = RuleBasedCurator()
        let blurb = "Premium loose jasmine green tea leaves, 8.46 oz."
        let product = liveProduct(blurb)
        let profile = TasteProfile(vibe: [], leanings: [], budgetComfort: 0.5, signatureLine: "")

        let owner = curator.rationale(for: product, profile: profile)
        #expect(!owner.contains(blurb))
        #expect(!owner.isEmpty)

        let mom = RecipientRef(id: "m", name: "Mom", accentHex: 0)
        let gift = curator.rationale(for: product, profile: profile, recipient: mom)
        #expect(!gift.contains(blurb))
        #expect(gift.contains("Mom"))
    }

    // MARK: Model-rank reconciliation (the deterministic guarantee behind the model call)

    @Test("reconcile honors the model's order and keeps every product exactly once")
    func reconcileFullReorder() {
        let products = SeedData.hikeProducts
        let modelOrder = products.map(\.id).reversed().map { $0 }

        let result = AppleFoundationCurator.reconcile(modelIDs: modelOrder, candidates: products)

        #expect(result.map(\.id) == modelOrder)                       // exact model order
        #expect(Set(result.map(\.id)) == Set(products.map(\.id)))     // nothing dropped
        #expect(result.count == products.count)                       // nothing duplicated
    }

    @Test("reconcile appends products the model omitted, in deterministic candidate order")
    func reconcilePartial() {
        let products = SeedData.hikeProducts                          // baseline = deterministic order
        // Model only ranked two, and inverted them; the rest must follow in baseline order.
        let modelOrder = [products[2].id, products[0].id]

        let result = AppleFoundationCurator.reconcile(modelIDs: modelOrder, candidates: products)

        #expect(result.prefix(2).map(\.id) == modelOrder)             // model's picks lead
        let tail = products.filter { $0.id != products[0].id && $0.id != products[2].id }
        #expect(result.suffix(from: 2).map(\.id) == tail.map(\.id))   // tail keeps baseline order
        #expect(Set(result.map(\.id)) == Set(products.map(\.id)))     // total order, nothing lost
    }

    // MARK: Map-reduce ranking tournament (the pure chunking + promotion behind the model calls)

    private func decoy(_ id: String) -> Product {
        Product(id: id, name: id, shop: Shop(id: "s", name: "s"), price: 1, rating: 0, reviews: 0,
                rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
                variants: [Variant(id: "\(id).v", title: "v", price: 1, checkoutURL: nil)])
    }

    @Test("chunked splits in order, last chunk may be smaller, empty stays empty")
    func chunkedSplits() {
        let items = (1...25).map { decoy("p\($0)") }
        let chunks = AppleFoundationCurator.chunked(items, size: 6)
        #expect(chunks.map(\.count) == [6, 6, 6, 6, 1])                 // 5 chunks, last is the remainder
        #expect(chunks.flatMap { $0 }.map(\.id) == items.map(\.id))     // order preserved, nothing lost
        #expect(AppleFoundationCurator.chunked([], size: 6).isEmpty)    // empty input → no chunks
        // A pool that already fits one chunk is a single chunk (the tournament's base case).
        #expect(AppleFoundationCurator.chunked(Array(items.prefix(4)), size: 6).count == 1)
    }

    @Test("advance promotes the top `keep` of each chunk and gathers the rest in order")
    func advancePromotes() {
        // Two chunks, each already ranked best-first.
        let a = (1...6).map { decoy("a\($0)") }
        let b = (1...6).map { decoy("b\($0)") }
        let (winners, losers) = AppleFoundationCurator.advance([a, b], keep: 2)
        #expect(winners.map(\.id) == ["a1", "a2", "b1", "b2"])                  // top-2 of each, in chunk order
        #expect(losers.map(\.id) == ["a3", "a4", "a5", "a6", "b3", "b4", "b5", "b6"])
        // keep ≥ chunk size → everyone is a winner, no losers (so the tournament can't strand items).
        let (allWin, none) = AppleFoundationCurator.advance([a], keep: 10)
        #expect(allWin.count == 6)
        #expect(none.isEmpty)
    }

    @Test("advance always shrinks a multi-chunk field so the tournament converges")
    func advanceConverges() {
        // 25 items → chunks of 6 → promoting 2 each must yield fewer than 25 (strict shrink).
        let items = (1...25).map { decoy("p\($0)") }
        let chunks = AppleFoundationCurator.chunked(items, size: 6)
        let (winners, _) = AppleFoundationCurator.advance(chunks, keep: 2)
        #expect(winners.count < items.count)
        #expect(winners.count == 9)   // 2+2+2+2+1
    }

    @Test("reconcile ignores hallucinated IDs and collapses duplicates")
    func reconcileGarbage() {
        let products = SeedData.hikeProducts
        let modelOrder = [
            products[1].id, "hike.does-not-exist", products[1].id,    // dupe + unknown ID
            products[0].id, "", products[0].id,
        ]

        let result = AppleFoundationCurator.reconcile(modelIDs: modelOrder, candidates: products)

        #expect(result.prefix(2).map(\.id) == [products[1].id, products[0].id]) // deduped, no ghosts
        #expect(result.count == products.count)                                 // still total + unique
        #expect(Set(result.map(\.id)) == Set(products.map(\.id)))
    }

    @Test("reconcile with no usable IDs falls back to the deterministic candidate order")
    func reconcileEmpty() {
        let products = SeedData.hikeProducts

        let empty = AppleFoundationCurator.reconcile(modelIDs: [], candidates: products)
        let allBogus = AppleFoundationCurator.reconcile(modelIDs: ["nope", "also.nope"], candidates: products)

        #expect(empty.map(\.id) == products.map(\.id))               // unchanged order
        #expect(allBogus.map(\.id) == products.map(\.id))            // unchanged order
    }

    @Test("withRationale replaces only the rationale")
    func withRationale() {
        let original = SeedData.hikeProducts[0]
        let updated = original.withRationale("A quiet, weatherproof yes.")

        #expect(updated.rationale == "A quiet, weatherproof yes.")
        #expect(updated.id == original.id)
        #expect(updated.name == original.name)
        #expect(updated.price == original.price)
        #expect(updated.imageURL == original.imageURL)
        #expect(updated.variants == original.variants)
    }

    @Test("A fallback reason produces an honest note; a chosen default stays silent")
    func curatorFallbackNotes() {
        #expect(CuratorTier.ruleBased(nil).fallbackNote == nil)
        #expect(CuratorTier.privateCloud.fallbackNote == nil)
        #expect(CuratorTier.onDevice.fallbackNote == nil)
        #expect(CuratorTier.ruleBased(.quotaExhausted).fallbackNote != nil)
        #expect(CuratorTier.ruleBased(.deviceNotEligible).fallbackNote != nil)
    }

    @Test("Default taste profile matches the brief")
    func defaultProfile() {
        let profile = SeedData.defaultTasteProfile
        #expect(profile.vibe == ["Quiet", "Earthy", "Built to last"])
        #expect(profile.budgetComfort == 0.6)
        #expect(SeedData.missions.count == 3)
    }
}
