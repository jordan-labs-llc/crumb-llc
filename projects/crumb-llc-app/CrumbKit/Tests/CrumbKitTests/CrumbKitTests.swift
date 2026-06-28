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
        // Every card carries the curator's rationale (matches rationale(for:profile:)).
        for product in deck.products {
            #expect(product.rationale == curator.rationale(for: product, profile: profile))
        }
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
