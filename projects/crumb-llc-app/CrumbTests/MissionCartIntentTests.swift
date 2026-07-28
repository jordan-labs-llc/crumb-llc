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

    // MARK: Foils are only offered where they are apples to apples

    /// A kit mission's candidates are the union of every part's search with no record of which
    /// part found what, so the products beside the beans are the brew mat and the kettle. Offering
    /// those as "Costs less" and "A step up" would be confidently wrong.
    @Test("A multi-part kit mission offers no foils")
    func kitMissionHasNoFoils() async throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: SeedData.coffee)          // 5 parts, not single-item
        await model.loadCandidates(for: SeedData.coffee)

        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(model.isSingleProductMission == false)
        #expect(!interaction.options.contains { $0.id.hasPrefix("foil:") },
                "kit parts are not alternatives to each other")
        #expect(interaction.options.contains { $0.id == "show-another" },
                "with no foils, the generic offer comes back")
    }

    @Test("A single-item mission does offer foils")
    func singleItemMissionHasFoils() async throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: SeedData.coffee.settingSingleItem(true))
        await model.loadCandidates(for: SeedData.coffee.settingSingleItem(true))

        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.options.contains { $0.id.hasPrefix("foil:") })
    }
}
