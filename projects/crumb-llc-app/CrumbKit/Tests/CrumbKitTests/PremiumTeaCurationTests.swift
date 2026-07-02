import Testing
import Foundation
@testable import CrumbKit

@Suite("Premium jasmine tea curation (#58)")
struct PremiumTeaCurationTests {

    private let curator = RuleBasedCurator()
    private let profile = TasteProfile(vibe: [], leanings: [], budgetComfort: 0.6, signatureLine: "")

    private let mission = ShoppingTask(
        id: "goal.premium-jasmine-tea",
        title: "Premium jasmine tea",
        subtitle: "A quiet sip for a discerning tea buyer",
        plan: ["Premium jasmine tea"],
        curatorNote: "",
        accentHex: 0,
        candidateIDs: [],
        searchQueries: ["premium jasmine tea"]
    )

    @Test("Premium jasmine fixture ranks specialty tea above generic, sample, and bulk picks")
    func ranksSpecialtyTeaFirst() async {
        let ranked = curator.rank(Self.fixtureDeck, for: profile, mission: mission)

        #expect(Set(ranked.prefix(2).map(\.id)) == ["rishi", "goldenmoon"])
        #expect(["rishi", "goldenmoon"].contains(ranked.first?.id ?? ""))
        #expect(ranked.firstIndex { $0.id == "sample" }! > ranked.firstIndex { $0.id == "rishi" }!)
        #expect(ranked.firstIndex { $0.id == "bulk" }! > ranked.firstIndex { $0.id == "goldenmoon" }!)
        #expect(ranked.firstIndex { $0.id == "generic-cross-border" }! > ranked.firstIndex { $0.id == "rishi" }!)
    }

    @Test("Premium jasmine floor rationale names concrete quality signals")
    func rationaleNamesQualitySignals() async {
        let deck = await curator.curate(Self.fixtureDeck, for: profile, mission: mission)
        let rishi = deck.products.first { $0.id == "rishi" }!
        let sample = deck.products.first { $0.id == "sample" }!
        let generic = deck.products.first { $0.id == "generic-cross-border" }!

        #expect(rishi.rationale.contains("Premium jasmine fit"))
        #expect(rishi.rationale.contains("loose-leaf"))
        #expect(rishi.rationale.contains("specialty tea merchant"))
        #expect(sample.rationale.contains("less premium than the loose-leaf picks"))
        #expect(generic.rationale.contains("Cross-border seller"))
    }

    @Test("Non-tea missions keep the existing profile ranking")
    func nonTeaRankingUnchanged() async {
        let products = [
            Self.product("a", "Lower price", price: 15, rating: 4.2, reviews: 100, desc: "Simple mission fit."),
            Self.product("b", "Better rated", price: 30, rating: 4.8, reviews: 500, desc: "Simple mission fit."),
        ]
        let mission = ShoppingTask(
            id: "goal.coffee",
            title: "Coffee kit",
            subtitle: "",
            plan: ["Coffee beans"],
            curatorNote: "",
            accentHex: 0,
            candidateIDs: [],
            searchQueries: ["coffee beans"]
        )

        let plain = await curator.rank(products, for: profile).map(\.id)
        let missionAware = curator.rank(products, for: profile, mission: mission).map(\.id)

        #expect(missionAware == plain)
    }

    private static let fixtureDeck: [Product] = [
        product(
            "generic-cross-border",
            "Jasmine Tea",
            shop: Shop(id: "thefoalyard.co.uk", name: "thefoalyard.co.uk"),
            price: 17,
            desc: "Jasmine tea."
        ),
        product(
            "rishi",
            "Jasmine",
            shop: Shop(id: "rishi-tea.com", name: "rishi-tea.com"),
            price: 58,
            desc: "Organic loose leaf jasmine green tea, traditionally scented for a floral cup."
        ),
        product(
            "sample",
            "Organic Silk Dragon Jasmine Tea Pack of 12 Sachets",
            shop: Shop(id: "davidstea.com", name: "davidstea.com"),
            price: 6.15,
            desc: "Organic jasmine green tea sachets."
        ),
        product(
            "bulk",
            "Jasmine Tea Case Pack",
            shop: Shop(id: "restaurant-supply.test", name: "Restaurant Supply"),
            price: 90,
            desc: "Bulk foodservice jasmine tea case pack."
        ),
        product(
            "goldenmoon",
            "Imperial Jasmine Pearls",
            shop: Shop(id: "goldenmoontea.com", name: "Golden Moon Tea"),
            price: 22,
            desc: "Loose leaf jasmine pearls made from green tea leaves."
        ),
    ]

    private static func product(
        _ id: String,
        _ name: String,
        shop: Shop = Shop(id: "shop", name: "Shop"),
        price: Decimal,
        rating: Double = 0,
        reviews: Int = 0,
        desc: String
    ) -> Product {
        Product(
            id: id,
            name: name,
            shop: shop,
            price: price,
            rating: rating,
            reviews: reviews,
            rationale: desc,
            symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: price, checkoutURL: nil)]
        )
    }
}
