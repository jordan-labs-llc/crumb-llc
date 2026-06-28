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

    @Test("Default taste profile matches the brief")
    func defaultProfile() {
        let profile = SeedData.defaultTasteProfile
        #expect(profile.vibe == ["Quiet", "Earthy", "Built to last"])
        #expect(profile.budgetComfort == 0.6)
        #expect(SeedData.missions.count == 3)
    }
}
