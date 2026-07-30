import Testing
import Foundation
@testable import CrumbKit

/// What Home may show and answer for a mission's frozen question.
@Suite("MissionHomeInbox")
struct MissionHomeDecisionTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let taste = TasteProfile(
        vibe: ["calm"], leanings: ["durable"], budgetComfort: 0.4,
        signatureLine: "quietly useful"
    )

    /// A real catalog title, verbatim from a live gather — clause and all.
    static let rawTitle = "Ceramic Heart Trinket Tray | I Love That You Are My Sister"

    static let tray = Product(
        id: "p1",
        name: rawTitle,
        shop: SeedData.Shops.millOak,
        price: 18,
        rating: 4.7,
        reviews: 31,
        rationale: "Hand-glazed, and the only piece here that isn’t a mug.",
        symbol: "heart",
        gradient: SeedData.Gradient.pine,
        variants: [Variant(id: "p1-v", title: "Default", price: 18)]
    )

    /// A thread carrying exactly the shape `installProductQuestion` produces: the product in
    /// `candidates`, a posted prompt with its snapshot block, and an interaction whose own
    /// `question` names the raw product.
    private func productThread(
        options: [MissionInteractionOption] = [
            MissionInteractionOption(id: "add", label: "Add"),
            MissionInteractionOption(id: "skip", label: "Skip"),
        ],
        promptText: String = "How does this one look?"
    ) throws -> MissionThread {
        var thread = MissionThread(goal: "A birthday gift for my sister", taste: Self.taste, now: Self.now)
        thread.phase = .deckReady
        thread.candidates = [Self.tray]
        let variant = Self.tray.variants[0]
        thread.appendEvent(
            kind: .assistantMessage,
            text: promptText,
            createdAt: Self.now,
            productID: Self.tray.id,
            blocks: [.product(MissionProductSnapshot(product: Self.tray, variant: variant))]
        )
        let promptID = try #require(thread.timeline.last?.id)
        _ = try thread.installInteraction(
            promptEventID: promptID,
            subjectRevision: thread.revision,
            kind: .productDecision,
            question: "What should I do with \(Self.rawTitle)?",
            options: options,
            allowsFreeText: true,
            resolver: .product(productID: Self.tray.id, variantID: variant.id),
            createdAt: Self.now
        )
        return thread
    }

    /// A question with options but no product — the other shape Home can finish.
    private func clarificationThread(promptText: String = "Who is this for?") throws -> MissionThread {
        var thread = MissionThread(goal: "A birthday gift", taste: Self.taste, now: Self.now)
        thread.appendEvent(kind: .assistantMessage, text: promptText, createdAt: Self.now)
        let promptID = try #require(thread.timeline.last?.id)
        _ = try thread.installInteraction(
            promptEventID: promptID,
            subjectRevision: thread.revision,
            kind: .clarification,
            question: "Who is this for?",
            options: [
                MissionInteractionOption(id: "me", label: "Me"),
                MissionInteractionOption(id: "gift", label: "Someone else"),
            ],
            allowsFreeText: true,
            resolver: .clarification(contextID: "recipient"),
            createdAt: Self.now
        )
        return thread
    }

    @Test("the decision carries the posted prompt, not the resolver's question")
    func prefersThePostedPrompt() throws {
        let decision = try #require(MissionHomeInbox.decision(for: productThread()))
        #expect(decision.prompt == "How does this one look?")
        // The resolver's own phrasing is still there — Home just stops quoting it.
        #expect(decision.interaction.question.hasPrefix("What should I do with"))
    }

    @Test("the product under decision comes with the question")
    func carriesTheProduct() throws {
        let decision = try #require(MissionHomeInbox.decision(for: productThread()))
        let product = try #require(decision.product)
        #expect(product.productID == "p1")
        #expect(product.presentedPrice == 18)
        #expect(product.merchant == SeedData.Shops.millOak.name)
        #expect(product.rationale.hasPrefix("Hand-glazed"))
        // The merchandising clause is gone by the time Home reads it.
        #expect(decision.productName == "Ceramic Heart Trinket Tray")
    }

    @Test("a question with no product still resolves, with no product attached")
    func productIsOptional() throws {
        let decision = try #require(MissionHomeInbox.decision(for: clarificationThread()))
        #expect(decision.product == nil)
        #expect(decision.productName == nil)
        #expect(decision.prompt == "Who is this for?")
    }

    @Test("an empty prompt falls back to the interaction's own question")
    func fallsBackToTheInteractionQuestion() throws {
        let decision = try #require(MissionHomeInbox.decision(for: clarificationThread(promptText: "   ")))
        #expect(decision.prompt == "Who is this for?")
    }

    @Test("a free-text-only question is not answerable from Home")
    func rejectsOptionlessQuestions() throws {
        // No options means the answer needs a field, and Home has none.
        var thread = MissionThread(goal: "A birthday gift", taste: Self.taste, now: Self.now)
        thread.appendEvent(kind: .assistantMessage, text: "What's your budget?", createdAt: Self.now)
        let promptID = try #require(thread.timeline.last?.id)
        _ = try thread.installInteraction(
            promptEventID: promptID,
            subjectRevision: thread.revision,
            kind: .clarification,
            question: "What's your budget?",
            options: [],
            allowsFreeText: true,
            resolver: .clarification(contextID: "budget"),
            createdAt: Self.now
        )
        #expect(MissionHomeInbox.decision(for: thread) == nil)
    }

    @Test("a thread under blocking recovery is never answerable from Home")
    func rejectsBlockedThreads() throws {
        var thread = try productThread()
        thread.blockingRecovery = .savePendingInteraction(failedRevision: thread.revision)
        #expect(MissionHomeInbox.decision(for: thread) == nil)
    }

    @Test("a thread with no pending question has no decision")
    func rejectsQuietThreads() {
        var thread = MissionThread(goal: "A birthday gift", taste: Self.taste, now: Self.now)
        thread.phase = .gathering
        #expect(MissionHomeInbox.decision(for: thread) == nil)
    }
}
