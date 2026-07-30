import Testing
import Foundation
import CrumbKit
@testable import Crumb

/// End-to-end coverage for the reported failure, through the real question/answer path.
///
/// ``MissionUtteranceTests`` pins the parse. This suite pins the consequence: that a decision and
/// a request to buy, typed in one breath, actually reach the kit and the cart instead of being
/// re-curated into a longer list of options.
@Suite("Mission cart intent")
@MainActor
struct MissionCartIntentTests {

    private static func modelOnAProductQuestion() async throws -> (AppModel, Product) {
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.coffee)
        await model.beginCuration()
        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .productDecision)
        guard case .product(let productID, _) = interaction.resolver else {
            Issue.record("expected a product question, got \(interaction.resolver)")
            throw CancellationError()
        }
        let product = try #require(model.activeThread?.candidates.first { $0.id == productID })
        return (model, product)
    }

    private static func type(_ text: String, into model: AppModel) throws {
        let interaction = try #require(model.activeThread?.pendingInteraction)
        let thread = try #require(model.activeThread)
        _ = model.submitMissionAnswer(MissionInteractionSubmission(
            threadID: thread.id,
            interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision,
            answer: .freeText(text)
        ))
    }

    // MARK: The reported session

    @Test("\"I like it. Let's create a cart.\" keeps the pick and opens the cart")
    func reportedSessionNowWorks() async throws {
        let (model, product) = try await Self.modelOnAProductQuestion()

        try Self.type("I like it. Let\u{2019}s create a cart.", into: model)

        let thread = try #require(model.activeThread)
        // The decision landed: the thing they said yes to is in the kit.
        #expect(thread.kit.contains { $0.product.id == product.id })
        // And the next step landed: they are looking at the cart, not at more options.
        #expect(model.route == .cart)
    }

    /// The precise regression. The old reducer answered this message with `.refine`, which
    /// re-ran curation and narrated "I updated the picks to match."
    @Test("It is not treated as a request to change the picks")
    func isNotARefinement() async throws {
        let (model, _) = try await Self.modelOnAProductQuestion()
        let before = try #require(model.activeThread).refinementTurns

        try Self.type("I like it. Let\u{2019}s create a cart.", into: model)

        let thread = try #require(model.activeThread)
        #expect(thread.refinementTurns == before, "the message must not be logged as a refinement")
        #expect(!thread.timeline.contains { $0.kind == .refinementRequested })
    }

    // MARK: The neighbouring intents

    @Test("A bare yes keeps the pick and stays in the mission")
    func bareAssentStaysPut() async throws {
        let (model, product) = try await Self.modelOnAProductQuestion()

        try Self.type("looks good", into: model)

        let thread = try #require(model.activeThread)
        #expect(thread.kit.contains { $0.product.id == product.id })
        #expect(model.route != .cart, "assent alone is not a request to leave for the cart")
    }

    @Test("\"Buy it\" keeps the pick and starts checkout")
    func buyItStartsCheckout() async throws {
        let (model, product) = try await Self.modelOnAProductQuestion()

        try Self.type("buy it", into: model)

        let thread = try #require(model.activeThread)
        #expect(thread.kit.contains { $0.product.id == product.id })
        #expect(model.route == .cart)
    }

    @Test("An unrecognised sentence is still a refinement")
    func unknownStillRefines() async throws {
        let (model, _) = try await Self.modelOnAProductQuestion()

        try Self.type("something less bitter and under $20", into: model)

        #expect(model.route != .cart)
        let thread = try #require(model.activeThread)
        #expect(thread.kit.isEmpty, "a change request must not add anything")
    }

    @Test("Asking for a cart with an empty kit says so instead of navigating")
    func emptyKitCannotCheckOut() async throws {
        let (model, _) = try await Self.modelOnAProductQuestion()

        try Self.type("show me the cart", into: model)

        #expect(model.route != .cart)
        let thread = try #require(model.activeThread)
        #expect(thread.kit.isEmpty)
        #expect(thread.pendingInteraction != nil, "the person is left on a question they can act on")
    }

    // MARK: The kit question offers a way forward

    @Test("A kit question with something kept offers Check out")
    func kitQuestionOffersCheckout() async throws {
        let (model, _) = try await Self.modelOnAProductQuestion()
        try Self.type("add it", into: model)

        // Walk to the end of the deck so the kit question is the one on screen.
        var guardrail = 0
        while let interaction = model.activeThread?.pendingInteraction,
              interaction.kind == .productDecision, guardrail < 50 {
            try Self.type("skip", into: model)
            guardrail += 1
        }

        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .cartReview)
        #expect(interaction.options.contains { $0.id == "checkout" },
                "a finished kit must have a button that moves it forward")
        #expect(interaction.options.count <= 4, "the interaction contract caps a question at four")
    }

    // MARK: Foils are apples to apples, on a kit as much as on a shortlist

    /// A catalog that answers each part of a kit with several real options — the shape the live
    /// broker returns and the mock deliberately doesn't (it hands every query the same curated set).
    private struct PartedUCP: UCPClient {
        let byQuery: [String: [Product]]
        func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product] {
            byQuery[query] ?? []
        }
        func product(id: Product.ID) async throws -> Product { throw UCPError.productNotFound(id) }
        func assembleCart(_ items: [KitItem]) async throws -> Cart { Cart(items: items) }
        func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
            throw UCPError.emptyShopHandoff(shop.id)
        }
    }

    private static func kettleShaped(_ id: String, _ name: String, _ price: Decimal) -> Product {
        Product(
            id: id, name: name, shop: Shop(id: "shop", name: "Shop"), price: price,
            rating: 4.5, reviews: 100, rationale: "", symbol: "cup.and.saucer",
            gradient: SeedData.Gradient.ochre,
            variants: [Variant(id: "\(id).v", title: "Standard", price: price, checkoutURL: nil)]
        )
    }

    /// Two parts, three real kettles and one mat — so the deck holds both alternatives *and*
    /// unrelated parts, and the two must not be confused.
    private static func pourOverKit() -> (AppModel, ShoppingTask) {
        let task = ShoppingTask(
            id: "pour-over", title: "Set up my pour-over corner", subtitle: "Slower mornings",
            plan: ["Gooseneck kettle", "A tidy mat"], curatorNote: "", accentHex: 0,
            candidateIDs: [], searchQueries: ["gooseneck kettle", "brew mat"]
        )
        let ucp = PartedUCP(byQuery: [
            "gooseneck kettle": [
                kettleShaped("k1", "Heron Gooseneck Kettle", 79),
                kettleShaped("k2", "Fieldnote Gooseneck Kettle", 45),
                kettleShaped("k3", "Stagg Pour-Over Kettle", 129),
            ],
            "brew mat": [kettleShaped("m1", "Linen Brew Mat", 24)],
        ])
        return (AppModel(ucp: ucp, curator: RuleBasedCurator()), task)
    }

    /// The deferral this closes. A kit deck used to be one union with no record of which search
    /// found what, so foils were switched off wholesale rather than offer the brew mat as the
    /// cheaper version of a kettle. With the gather naming its searches, the alternatives are real.
    @Test("A multi-part kit mission offers foils from the same part")
    func kitMissionOffersSamePartFoils() async throws {
        let (model, task) = Self.pourOverKit()
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        let thread = try #require(model.activeThread)
        let interaction = try #require(thread.pendingInteraction)
        #expect(model.isSingleProductMission == false)
        guard case .product(let subjectID, _) = interaction.resolver else {
            Issue.record("expected a product question, got \(interaction.resolver)")
            return
        }
        let subject = try #require(thread.candidates.first { $0.id == subjectID })
        #expect(thread.part(of: subject) == "Gooseneck kettle",
                "a multi-part kit is walked a part at a time, starting at the first open one")

        let foilIDs = interaction.options.compactMap {
            $0.id.hasPrefix("foil:") ? String($0.id.dropFirst("foil:".count)) : nil
        }
        #expect(!foilIDs.isEmpty, "a part with three real options has alternatives worth showing")
        for id in foilIDs {
            let foil = try #require(thread.candidates.first { $0.id == id })
            #expect(thread.part(of: foil) == "Gooseneck kettle",
                    "\(foil.name) is a different part of the kit, not an alternative")
        }
        #expect(!foilIDs.contains("m1"), "the brew mat is not a cheaper kettle")
    }

    /// The other half of the same rule: a part the deck answers only once has nothing to compare,
    /// so the generic offer comes back rather than a foil drawn from a neighbouring part.
    @Test("A part with one candidate offers no foils")
    func lonePartFallsBackToShowAnother() async throws {
        let (model, task) = Self.pourOverKit()
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        // Answer down to the mat — the part the catalog returned exactly one option for.
        var guardrail = 0
        while let interaction = model.activeThread?.pendingInteraction,
              interaction.kind == .productDecision, guardrail < 20 {
            if case .product(let id, _) = interaction.resolver, id == "m1" { break }
            try Self.type("skip", into: model)
            guardrail += 1
        }
        let interaction = try #require(model.activeThread?.pendingInteraction)
        guard case .product("m1", _) = interaction.resolver else {
            Issue.record("expected the mat's question, got \(interaction.resolver)")
            return
        }
        #expect(!interaction.options.contains { $0.id.hasPrefix("foil:") })
        #expect(interaction.options.contains { $0.id == "show-another" })
    }

    @Test("A single-item mission compares its whole deck")
    func singleItemMissionHasFoils() async throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: SeedData.coffee.settingSingleItem(true))
        await model.loadCandidates(for: SeedData.coffee.settingSingleItem(true))

        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.options.contains { $0.id.hasPrefix("foil:") })
    }

    // MARK: One part at a time

    @Test("A kit mission asks about each part in plan order, not deck order")
    func kitMissionWalksThePlan() async throws {
        let (model, task) = Self.pourOverKit()
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        // Keep the kettle it recommends; the next question must move on to the mat rather than
        // walking the two remaining kettles first.
        try Self.type("add it", into: model)
        let interaction = try #require(model.activeThread?.pendingInteraction)
        guard case .product(let nextID, _) = interaction.resolver else {
            Issue.record("expected a product question, got \(interaction.resolver)")
            return
        }
        #expect(nextID == "m1", "the kettle part is covered — the open part is the mat")
    }
}
