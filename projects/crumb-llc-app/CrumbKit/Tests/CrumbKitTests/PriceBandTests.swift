import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the price-sanity backstop (#20): a robust median ± k·MAD
/// band, only ever demoting the high side, and only a genuine outlier — never a merely wide-but-sane
/// spread. The reorder is pure, so a mispriced catalog item can never enter the top of the deck.
@Suite("PriceBand")
struct PriceBandTests {

    private let shop = Shop(id: "shop", name: "Shop")

    private func product(_ id: String, price: Decimal) -> Product {
        Product(
            id: id, name: id, shop: shop, price: price, rating: 0, reviews: 0,
            rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: price, checkoutURL: nil)]
        )
    }

    private func deck(_ prices: [Decimal]) -> [Product] {
        prices.enumerated().map { product("p\($0.offset)", price: $0.element) }
    }

    @Test("A ~70×-median price outlier is demoted out of the deck top")
    func demotesOutlier() {
        // A sane jasmine-tea deck plus the real $1,450 "Premium Black Tea Leaf" leading the order.
        let d = deck([1450, 4, 4.26, 7, 7.99, 28.90, 58, 12, 9])
        let saned = PriceBand.priceSane(d)
        #expect(saned.first?.id != "p0")                        // the $1,450 no longer leads
        #expect(saned.last?.id == "p0")                         // it's sunk to the tail
        #expect(!saned.prefix(3).contains { $0.id == "p0" })    // never in the top-3
        // Legitimately-premium picks (the $58 Rishi) are NOT demoted.
        #expect(saned.prefix(saned.count - 1).contains { $0.id == "p6" })
    }

    @Test("A tight, sane distribution with one modestly-pricier pick is left alone")
    func keepsModestlyPricier() {
        let d = deck([10, 12, 11, 9, 13, 30])
        let saned = PriceBand.priceSane(d)
        #expect(saned.map(\.id) == d.map(\.id))   // order unchanged; nothing demoted
    }

    @Test("Too few candidates to judge a norm → no band → deck unchanged")
    func tooFewNoBand() {
        let d = deck([5, 5000, 6])   // only 3 items — below minCount
        #expect(PriceBand.from(d) == nil)
        #expect(PriceBand.priceSane(d).map(\.id) == d.map(\.id))
    }

    @Test("Demotion is stable: in-band and outlier groups each keep their relative order")
    func stablePartition() {
        let d = deck([9, 2000, 10, 3000, 11, 12, 13, 14])
        let saned = PriceBand.priceSane(d)
        // Two outliers (p1=2000, p3=3000) go last, in their original relative order.
        #expect(saned.suffix(2).map(\.id) == ["p1", "p3"])
        // The in-band items keep their order ahead of them.
        #expect(saned.prefix(6).map(\.id) == ["p0", "p2", "p4", "p5", "p6", "p7"])
    }

    @Test("median handles odd and even counts")
    func medianStat() {
        #expect(PriceBand.median([1, 2, 3]) == 2)
        #expect(PriceBand.median([1, 2, 3, 4]) == 2.5)
    }

    @Test("The high cut floors the spread so a zero-MAD cluster isn't over-trimmed")
    func zeroMADSpreadFloor() {
        let d = deck(Array(repeating: 20, count: 8))   // all identical → MAD 0
        let band = PriceBand.from(d)
        // spread floors to 10% of median (2); cut = max(20 + 6·2, 20·10) = 200.
        #expect(band?.highCut == 200)
    }
}
