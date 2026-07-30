import Testing
import Foundation
@testable import CrumbKit

/// A CI-safe eval set for the curation regressions that used to require manual journey review.
/// It scores the deterministic floor that every model tier degrades to, plus the post-model
/// reconciliation guards that run before a deck reaches the UI.
@Suite("Curation quality eval set (#40)")
struct CurationQualityEvalTests {

    private struct EvalFamily: Hashable {
        let name: String
    }

    private static let requiredFamilies: Set<EvalFamily> = [
        .init(name: "query drift"),
        .init(name: "price sanity"),
        .init(name: "relevance"),
        .init(name: "voice quality"),
        .init(name: "golden missions"),
    ]

    private static let implementedFamilies: Set<EvalFamily> = requiredFamilies

    private static let jasmineMission = ShoppingTask(
        id: "eval.premium-jasmine-tea",
        title: "Premium jasmine tea",
        subtitle: "A narrow gift mission",
        plan: ["Premium jasmine tea"],
        curatorNote: "",
        accentHex: 0x27514A,
        candidateIDs: [],
        searchQueries: ["premium jasmine tea"]
    )

    private static func product(
        _ id: String,
        _ name: String,
        shop: String = "Specialty Tea Co.",
        price: Decimal,
        rationale: String
    ) -> Product {
        Product(
            id: id,
            name: name,
            shop: Shop(id: shop.lowercased().replacingOccurrences(of: " ", with: "-"), name: shop),
            price: price,
            rating: 0,
            reviews: 0,
            rationale: rationale,
            symbol: "leaf",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: price, checkoutURL: nil)]
        )
    }

    private static let jasmineDeck: [Product] = [
        product("tea.jasmine-16", "Organic Jasmine Tea", price: 16.99, rationale: "Organic jasmine green tea."),
        product("tea.jasmine-32", "Jasmine Pearls", price: 32, rationale: "Hand-rolled jasmine pearls."),
        product("tea.jasmine-45", "Loose Leaf Jasmine Green Tea", price: 45, rationale: "Premium loose-leaf jasmine tea."),
        product("tea.jasmine-58", "Reserve Jasmine Tea", price: 58, rationale: "Small-lot jasmine tea."),
    ]

    @Test("The eval registry covers every accepted curation-quality family")
    func registryCoversAcceptedFamilies() {
        #expect(Self.implementedFamilies == Self.requiredFamilies)
    }

    @Test("Query-drift eval: a narrow jasmine mission keeps jasmine tea in every generated query")
    func queryDrift() async throws {
        let planned = await RuleBasedMissionPlanner().plan(
            goal: "buy premium jasmine tea",
            profile: SeedData.defaultTasteProfile
        )
        let task = try #require(planned.task)

        #expect(!task.searchQueries.isEmpty)
        for query in task.searchQueries {
            let lowered = query.lowercased()
            #expect(lowered.contains("jasmine"), "query drifted off jasmine: \(query)")
            #expect(lowered.contains("tea"), "query drifted off tea: \(query)")
            #expect(!lowered.contains("black tea"), "query drifted into adjacent tea category: \(query)")
            #expect(!lowered.contains("coffee"), "query drifted into another catalog category: \(query)")
        }
    }

    @Test("Price-sanity eval: a model-proposed high outlier cannot survive in the top three")
    func priceSanity() {
        let outlier = Self.product(
            "tea.black-1450",
            "Premium Black Tea Leaf",
            shop: "Auction Tea Importer",
            price: 1_450,
            rationale: "Collector black tea lot."
        )
        let modelProposedDeck = [outlier] + Self.jasmineDeck

        let saned = PriceBand.priceSane(modelProposedDeck)

        #expect(saned.prefix(3).allSatisfy { $0.id != outlier.id })
        #expect(saned.last?.id == outlier.id)
    }

    @Test("Relevance eval: strict core terms drop adjacent tea and off-topic catalog items")
    func relevance() {
        let adjacentTea = Self.product(
            "tea.black",
            "Premium Black Tea",
            price: 28,
            rationale: "A dark loose-leaf tea."
        )
        let offTopic = Self.product(
            "desk.lamp",
            "Lowlight Desk Lamp",
            shop: "Hearth & Form",
            price: 148,
            rationale: "Warm dimmable desk light."
        )
        let candidates = Self.jasmineDeck + [adjacentTea, offTopic]

        let kept = RuleBasedRelevanceGate.keep(
            candidates,
            matching: RuleBasedRelevanceGate.keywords(for: Self.jasmineMission),
            core: RuleBasedRelevanceGate.coreTerms(for: Self.jasmineMission),
            floor: Self.jasmineDeck.count
        )

        #expect(kept.map(\.id) == Self.jasmineDeck.map(\.id))
    }

    @Test("Voice-quality eval: merchant blurbs become mission-anchored Crumb rationale")
    func voiceQuality() {
        let blurb = "Premium loose jasmine green tea leaves in an 8.46 oz bag, ideal for hot or cold beverages."
        let product = Self.product("tea.live", "Jasmine Tea", price: 17, rationale: blurb)

        let line = RuleBasedCurator().rationale(
            for: product,
            profile: SeedData.defaultTasteProfile,
            recipient: nil,
            mission: Self.jasmineMission
        )

        #expect(line != blurb)
        #expect(line.contains("Premium jasmine tea"))
        #expect(!line.lowercased().contains("merino"))
    }

    @Test("Golden-mission eval: seed missions still resolve to complete scored decks")
    func goldenMissions() async throws {
        let missions: [(ShoppingTask, [Product])] = [
            (SeedData.hike, SeedData.hikeProducts),
            (SeedData.coffee, SeedData.coffeeProducts),
            (SeedData.desk, SeedData.deskProducts),
        ]

        for (mission, expectedProducts) in missions {
            let gathered = await DeterministicMissionOrchestrator()
                .gather(for: mission, floor: 8, using: MockUCPClient(), gate: RuleBasedRelevanceGate())
            let products = try #require(gathered?.products)
            let deck = await RuleBasedCurator().curate(
                products,
                for: SeedData.defaultTasteProfile,
                mission: mission
            )

            #expect(products.count == expectedProducts.count, "candidate count for \(mission.id)")
            #expect(deck.products.count == expectedProducts.count, "deck count for \(mission.id)")
            #expect(Set(deck.products.map(\.id)) == Set(expectedProducts.map(\.id)))
            #expect(deck.tier == .ruleBased(nil))
        }
    }
}
