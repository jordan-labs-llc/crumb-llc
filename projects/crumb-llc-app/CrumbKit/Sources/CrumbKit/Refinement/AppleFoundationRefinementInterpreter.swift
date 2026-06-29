import Foundation
import FoundationModels

/// The "real" refinement interpreter, built on Apple's Foundation Models — the agent that
/// actually *reads* "make it cheaper, but keep the kettle" into a directive. It mirrors
/// ``AppleFoundationMissionPlanner`` / ``AppleFoundationCurator`` exactly:
/// ``RuleBasedRefinementInterpreter`` stays the offline floor, and one guided `@Generable` call
/// turns the latest refinement (in the context of the running conversation) into a structured
/// ``RefinementDirective``.
///
/// ## Tiers & degrade order (same story as the curator/planner)
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — gated behind
///    `CRUMB_PCC_ENABLED` because *constructing or querying* that type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process (an uncatchable
///    fatal error, not a throw). See the identical gate in ``AppleFoundationCurator``.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, no entitlement, the working
///    primary today.
/// 3. **Rule-based** — ``RuleBasedRefinementInterpreter``'s chip + keyword heuristic, used when
///    neither model is usable. It reports *why* it degraded so the Curate screen can be honest.
///
/// ## The interpretation call is the tier probe
/// Like the planner's, the single guided generation proves the tier: if it throws (offline /
/// system not ready) the interpreter degrades to the next tier / the rule-based floor. The
/// model's draft is then folded back by the pure, unit-tested ``directive(from:tier:)`` — which
/// trims, dedupes, and caps exactly like the rule-based floor's reconcile, so a hallucinated or
/// half-formed draft can never reach the curator.
public struct AppleFoundationRefinementInterpreter: RefinementInterpreter {

    /// The deterministic floor: the degrade target and the source of the shared `cleanDirective`.
    private let rule = RuleBasedRefinementInterpreter()

    public init() {}

    public func interpret(
        _ refinement: String,
        conversation: [String],
        mission: ShoppingTask,
        profile: TasteProfile
    ) async -> InterpretedRefinement {
        let trimmed = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty refinement never reaches the model — there's nothing to read.
        guard !trimmed.isEmpty else {
            return RuleBasedRefinementInterpreter.interpret(text: trimmed, reason: nil)
        }

        // Tier 1 — Private Cloud Compute, gated behind `CRUMB_PCC_ENABLED` for the entitlement-trap
        // reason (see the curator): constructing/querying the type without the entitlement traps.
        #if CRUMB_PCC_ENABLED
        let pcc = PrivateCloudComputeLanguageModel()
        if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
            if let read = try? await read(trimmed, conversation, mission, profile, model: pcc, deepReasoning: true, tier: .privateCloud) {
                return read
            }
            // Interpretation probe failed (offline / transient) — fall through to on-device.
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            if let read = try? await read(trimmed, conversation, mission, profile, model: device, deepReasoning: false, tier: .onDevice) {
                return read
            }
            return RuleBasedRefinementInterpreter.interpret(text: trimmed, reason: .offlineOrError)
        case let .unavailable(reason):
            return RuleBasedRefinementInterpreter.interpret(text: trimmed, reason: Self.map(reason))
        }
    }

    // MARK: Read

    /// Reading a refinement is a structured parse, not a creative task — run it cool.
    static let temperature = 0.3

    /// One guided generation reads the refinement into a ``RefinementDraft``, which the pure
    /// ``directive(from:tier:)`` folds into a clean directive. Throws when the call fails, so the
    /// tier cascade / rule-based fallback in ``interpret(_:conversation:mission:profile:)`` takes
    /// over.
    private func read<M: LanguageModel>(
        _ refinement: String,
        _ conversation: [String],
        _ mission: ShoppingTask,
        _ profile: TasteProfile,
        model: M,
        deepReasoning: Bool,
        tier: RefinementTier
    ) async throws -> InterpretedRefinement {
        let session = Self.refineSession(profile: profile, mission: mission, model: model, deepReasoning: deepReasoning)
        let response = try await session.respond(
            to: Self.prompt(for: refinement, conversation: conversation),
            generating: RefinementDraft.self
        )
        return Self.directive(from: response.content, tier: tier)
    }

    /// Builds the interpretation session: ``RefinerInstructions`` in a profile that declares the
    /// parse tuning + context policy. Reasoning is applied only on the deep-reasoning (PCC) tier —
    /// the on-device model rejects `.reasoningLevel`.
    static func refineSession<M: LanguageModel>(
        profile: TasteProfile,
        mission: ShoppingTask,
        model: M,
        deepReasoning: Bool
    ) -> LanguageModelSession {
        let base = LanguageModelSession.Profile { RefinerInstructions(profile: profile, mission: mission) }
            .model(model)
            .temperature(temperature)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
    }

    // MARK: Reconcile (pure — the unit-tested guarantee behind the model call)

    /// Folds the model's ``RefinementDraft`` into an ``InterpretedRefinement`` that is always safe
    /// to act on: the price string maps to the enum (anything unrecognized → `.none`), and the
    /// emphasis / queries / hints run through the same ``RuleBasedRefinementInterpreter/cleanDirective(_:)``
    /// as the deterministic floor (trim, drop blanks, dedupe, cap `addQueries`). The proven `tier`
    /// is preserved so the UI reports the real tier even when the directive came out thin.
    ///
    /// Pure and model-free: same draft always produces the same directive.
    static func directive(from draft: RefinementDraft, tier: RefinementTier) -> InterpretedRefinement {
        let raw = RefinementDirective(
            emphasis: draft.emphasis,
            addQueries: draft.addQueries,
            priceDirection: RefinementDirective.PriceDirection(rawValue:
                draft.priceDirection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ) ?? .none,
            removeHints: draft.removeHints
        )
        return InterpretedRefinement(
            directive: RuleBasedRefinementInterpreter.cleanDirective(raw),
            tier: tier
        )
    }

    // MARK: Prompt construction

    /// The prompt carries the running conversation so stacked refinements compose ("cheaper" then
    /// "but keep the kettle" reads as both), with the latest line called out as the active ask.
    static func prompt(for refinement: String, conversation: [String]) -> String {
        var lines: [String] = []
        let priorTurns = conversation.dropLast() // the latest line is `refinement`
        if !priorTurns.isEmpty {
            lines.append("Earlier in this refinement conversation, the user said:")
            for turn in priorTurns { lines.append("- \"\(turn)\"") }
            lines.append("")
        }
        lines.append("Now they say:")
        lines.append("\"\(refinement)\"")
        lines.append("")
        lines.append("Read this latest request into the structured refinement, honoring the "
            + "earlier ones where they still apply.")
        return lines.joined(separator: "\n")
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> RefinementTier.Fallback {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .offlineOrError
        }
    }
}

/// The refinement-interpreter instructions: the shared Crumb persona + the read-a-refinement role +
/// this user's taste + the mission + how to fill the structured directive. The dynamic-session
/// replacement for the interpreter's old hand-built instruction string.
struct RefinerInstructions: DynamicInstructions {
    let profile: TasteProfile
    let mission: ShoppingTask

    var body: some DynamicInstructions {
        CrumbPersona(recipient: nil)
        Instructions("The user is looking at a curated deck of products for a mission and is telling you how to change it. Read their request into a structured refinement.")
        TasteBlock(profile: profile, recipient: nil, includeBudget: false)
        MissionBlock(mission: mission)
        Instructions(Self.guide)
    }

    /// How to fill the structured refinement. Pure — unit-tested.
    static let guide = """
        Fill the refinement like this:
        - emphasis: a short note for how to re-rank and re-voice the EXISTING products (tone, \
        material, style, "fewer/stronger"). Empty if they only asked about price or to add/remove \
        a specific thing.
        - priceDirection: "cheaper", "pricier", or "none".
        - addQueries: ONLY when they ask for something that likely isn't in the deck yet (e.g. \
        "add rain pants" → ["rain pants"]). A few plain keywords each, no punctuation. Empty \
        otherwise — most refinements re-shape the existing deck and need no new search.
        - removeHints: keywords for things they want gone or de-emphasized (e.g. "no synthetic" \
        → ["synthetic"]). Empty otherwise.

        Never invent constraints they didn't ask for. Keep everything short.
        """
}

/// The structured output of a refinement call. Guided generation keeps the model returning a
/// clean, well-shaped directive rather than prose we'd have to parse;
/// ``AppleFoundationRefinementInterpreter/directive(from:tier:)`` then reconciles it.
@Generable
public struct RefinementDraft {
    @Guide(description: "A short note for re-ranking and re-voicing the existing products (tone, material, style). Empty if the request is only about price or adding/removing a specific item.")
    public var emphasis: String

    @Guide(description: "Price lean: 'cheaper', 'pricier', or 'none'.")
    public var priceDirection: String

    @Guide(description: "Catalog search queries ONLY for items the user asked to add that likely aren't in the deck, e.g. ['rain pants']. A few plain keywords each, no punctuation. Empty for most refinements.")
    public var addQueries: [String]

    @Guide(description: "Keywords for things the user wants removed or de-emphasized, e.g. ['synthetic']. Empty otherwise.")
    public var removeHints: [String]

    public init(
        emphasis: String,
        priceDirection: String,
        addQueries: [String],
        removeHints: [String]
    ) {
        self.emphasis = emphasis
        self.priceDirection = priceDirection
        self.addQueries = addQueries
        self.removeHints = removeHints
    }
}
