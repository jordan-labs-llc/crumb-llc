import Foundation

/// A mission's frozen question, as Home can present it: the interaction to answer, the sentence the
/// person was actually shown, and — when the question is about a product — the product itself.
///
/// Home used to render `interaction.question` alone. That string is written for the resolver
/// (`"What should I do with \(product.name)?"`), not for a reader: the mission screen posts a
/// different sentence — `"How does this one look?"` — together with a full product card. So Home
/// quoted a question nobody had been asked, about an object it did not show, and then offered three
/// buttons to decide it with.
public struct MissionHomeDecision: Hashable, Sendable {
    /// The frozen interaction. Answering it is still `AppModel.answerFromHome`'s job.
    public let interaction: MissionPendingInteraction
    /// The prompt as it was posted into the conversation, when there is one.
    public let prompt: String
    /// The product under decision, when the question is about one.
    public let product: MissionProductSnapshot?

    public init(interaction: MissionPendingInteraction, prompt: String, product: MissionProductSnapshot?) {
        self.interaction = interaction
        self.prompt = prompt
        self.product = product
    }

    /// The product's display name — the merchant's title with its merchandising clauses removed.
    public var productName: String? {
        product.map { TitleHygiene.displayName(for: $0.title, merchant: $0.merchant) }
    }
}

/// Whether a mission's pending question can be finished from Home, and what to show alongside it.
public enum MissionHomeInbox {

    /// The answerable decision for `thread`, or `nil` when Home must open the mission instead.
    ///
    /// Three things disqualify a question, and all three predate this type:
    /// - no options — a free-text-only question needs a field Home does not have;
    /// - a thread under blocking recovery — its state is not safe to mutate from here;
    /// - no pending interaction at all.
    public static func decision(for thread: MissionThread) -> MissionHomeDecision? {
        guard let interaction = thread.pendingInteraction,
              thread.blockingRecovery == nil,
              !interaction.options.isEmpty else { return nil }

        let promptEvent = thread.timeline.first { $0.id == interaction.promptEventID }

        // Prefer the sentence that was actually posted. Falling back to the interaction's own
        // question keeps every older thread — and any interaction whose prompt event has been
        // trimmed — rendering something rather than nothing.
        let posted = promptEvent?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = posted.isEmpty ? interaction.question : posted

        return MissionHomeDecision(
            interaction: interaction,
            prompt: prompt,
            product: promptEvent.flatMap(productSnapshot(in:))
        )
    }

    private static func productSnapshot(in event: MissionThreadEvent) -> MissionProductSnapshot? {
        for block in event.blocks {
            if case let .product(snapshot) = block { return snapshot }
        }
        return nil
    }
}
