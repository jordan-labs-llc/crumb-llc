import Foundation
import FoundationModels

/// The "real" recap writer, built on Apple's Foundation Models — the agent that actually *voices*
/// a finished kit. It mirrors ``AppleFoundationMissionPlanner`` / ``AppleFoundationCurator``
/// exactly: ``RuleBasedRecapWriter`` stays the offline floor, and one guided `@Generable` call
/// turns a kit into a crafted tag + a warm line in Crumb's voice.
///
/// ## Tiers & degrade order (same story as the planner)
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — gated behind
///    `CRUMB_PCC_ENABLED` because *constructing or querying* that type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process (an uncatchable
///    fatal error, not a throw). See the identical gate in ``AppleFoundationCurator``.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, no entitlement, the working primary.
/// 3. **Rule-based** — ``RuleBasedRecapWriter``'s deterministic recap, used when neither model is
///    usable. It reports *why* it degraded for parity with the other seams.
///
/// ## The writing call is the tier probe
/// Like the curator's ranking call and the planner's plan call, the single guided generation proves
/// the tier: if it throws (offline / system not ready) the writer degrades to the next tier / the
/// rule-based floor. The model's draft is then folded back by the pure, unit-tested
/// ``recap(from:goal:items:profile:tier:)`` — which trims, caps, and backfills any blank field from
/// the deterministic floor, so a model that returns half a recap never reaches the record.
public struct AppleFoundationRecapWriter: RecapWriter {

    /// The deterministic floor: the degrade target and the source of the shared pure helpers.
    public init() {}

    public func writeRecap(
        goal: String,
        plan: [String],
        items: [RecapFact],
        profile: TasteProfile,
        recipient: RecipientRef?
    ) async -> WrittenRecap {
        // An empty kit never reaches the model — there's nothing to voice (and we never save a
        // zero-item entry anyway).
        guard !items.isEmpty else {
            return RuleBasedRecapWriter.recap(goal: goal, plan: plan, items: items, profile: profile, recipient: recipient, reason: nil)
        }

        // Tier 1 — Private Cloud Compute, gated behind `CRUMB_PCC_ENABLED` for the entitlement-trap
        // reason (see the curator): constructing/querying the type without the entitlement traps.
        #if CRUMB_PCC_ENABLED
        let pcc = PrivateCloudComputeLanguageModel()
        if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
            if let written = try? await compose(goal, plan, items, profile, recipient, model: pcc, deepReasoning: true, tier: .privateCloud) {
                return written
            }
            // Writing probe failed (offline / transient) — fall through to on-device.
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            if let written = try? await compose(goal, plan, items, profile, recipient, model: device, deepReasoning: false, tier: .onDevice) {
                return written
            }
            return RuleBasedRecapWriter.recap(goal: goal, plan: plan, items: items, profile: profile, recipient: recipient, reason: .offlineOrError)
        case let .unavailable(reason):
            return RuleBasedRecapWriter.recap(goal: goal, plan: plan, items: items, profile: profile, recipient: recipient, reason: Self.map(reason))
        }
    }

    // MARK: Compose

    /// A warm, creative one-liner wants a touch more temperature than the structured seams.
    static let temperature = 0.7
    /// The recap is a short tag + line; a comfortable bound declared on the session's `Profile`.
    static let maxResponseTokens = 256

    /// One guided generation reads the kit into a ``RecapDraft``, which the pure
    /// ``recap(from:goal:items:profile:tier:)`` folds into a clean ``WrittenRecap``. Throws when the
    /// call fails, so the tier cascade / rule-based fallback in ``writeRecap`` takes over.
    private func compose<M: LanguageModel>(
        _ goal: String,
        _ plan: [String],
        _ items: [RecapFact],
        _ profile: TasteProfile,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool,
        tier: RecapTier
    ) async throws -> WrittenRecap {
        let session = Self.recapSession(profile: profile, recipient: recipient, model: model, deepReasoning: deepReasoning)
        let response = try await session.respond(
            to: Self.prompt(goal: goal, plan: plan, items: items, recipient: recipient),
            generating: RecapDraft.self
        )
        return Self.recap(from: response.content, goal: goal, plan: plan, items: items, profile: profile, recipient: recipient, tier: tier)
    }

    /// Builds the recap session: ``RecapInstructions`` in a profile that declares the recap tuning +
    /// context policy. Reasoning is applied only on the deep-reasoning (PCC) tier — the on-device
    /// model rejects `.reasoningLevel`.
    static func recapSession<M: LanguageModel>(
        profile: TasteProfile,
        recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) -> LanguageModelSession {
        let base = LanguageModelSession.Profile { RecapInstructions(profile: profile, recipient: recipient) }
            .model(model)
            .temperature(temperature)
            .maximumResponseTokens(maxResponseTokens)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
    }

    // MARK: Reconcile (pure — the unit-tested guarantee behind the model call)

    /// Folds the model's ``RecapDraft`` into a clean ``WrittenRecap``: each field is trimmed and
    /// length-capped; a blank field is backfilled from the deterministic floor, so a model that
    /// returns half a recap (or an over-long ramble) never reaches the record. Pure and model-free:
    /// same draft + kit always produces the same recap.
    static func recap(
        from draft: RecapDraft,
        goal: String,
        plan: [String],
        items: [RecapFact],
        profile: TasteProfile,
        recipient: RecipientRef? = nil,
        tier: RecapTier
    ) -> WrittenRecap {
        let tag = clean(draft.tag, max: maxTagLength)
        let line = clean(draft.line, max: maxLineLength)
        return WrittenRecap(
            tag: tag.isEmpty ? RuleBasedRecapWriter.tag(forGoal: goal) : tag,
            line: line.isEmpty ? RuleBasedRecapWriter.line(items: items, profile: profile, recipient: recipient) : line,
            tier: tier
        )
    }

    /// Trims whitespace and caps length on a word boundary (with an ellipsis) so a runaway
    /// generation can't blow out the card.
    static func clean(_ raw: String, max: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        let cut = String(trimmed.prefix(max))
        // Prefer to break at the last space inside the cap so we don't sever a word.
        if let space = cut.lastIndex(of: " ") {
            return cut[..<space].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return cut + "…"
    }

    /// Tag / line caps — a short title and a single warm line, never a paragraph.
    static let maxTagLength = 28
    static let maxLineLength = 120

    // MARK: Prompt construction

    static func prompt(goal: String, plan: [String], items: [RecapFact], recipient: RecipientRef? = nil) -> String {
        let kept = items
            .map { "- \($0.name) (\($0.shop))" }
            .joined(separator: "\n")
        let planText = plan.isEmpty ? "(none)" : plan.joined(separator: ", ")
        let giftLine = recipient.map { rec in
            let who = rec.trimmedRelationship.map { "\(rec.name) (\($0))" } ?? rec.name
            return "\nThis kit is a gift for \(who).\n"
        } ?? ""
        return """
        Their goal:
        "\(goal)"
        \(giftLine)
        The plan they ran: \(planText)

        What they kept:
        \(kept)

        Write the tag and the recap line.
        """
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> RecapTier.Fallback {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .offlineOrError
        }
    }
}

/// The recap-writer instructions: the shared Crumb persona + a gift-aware "writing a memory" context
/// + this user's (or the recipient's) taste + how to write the tag + line. The dynamic-session
/// replacement for the writer's old hand-built instruction string.
struct RecapInstructions: DynamicInstructions {
    let profile: TasteProfile
    let recipient: RecipientRef?

    var body: some DynamicInstructions {
        CrumbPersona(recipient: nil)
        Instructions(Self.context(recipient: recipient))
        TasteBlock(profile: profile, recipient: recipient, includeBudget: false)
        Instructions(Self.writeGuide(recipient: recipient))
    }

    /// The "what you're writing" framing, gift-aware. Pure — unit-tested.
    static func context(recipient: RecipientRef?) -> String {
        guard let recipient else {
            return "You are writing a one-line memory of a kit a person just put together, for "
                + "their history — something they'll enjoy seeing again later."
        }
        let who = recipient.trimmedRelationship.map { "\(recipient.name), \($0)" } ?? recipient.name
        return "You are writing a one-line memory of a gift kit someone just assembled for \(who)."
    }

    /// The tag + line guidance, gift-aware. Pure — unit-tested.
    static func writeGuide(recipient: RecipientRef?) -> String {
        let lineGuide = recipient.map { rec in
            "one short line in your voice that captures the gift — acknowledge it's for \(rec.name), grounded in what was actually kept, never inventing specifics"
        } ?? "one short line in your voice that captures the feeling of the kit — grounded in what they actually kept, never inventing specifics"
        return "Write a short 2 to 4 word tag naming the kit (like \"Rainy-hike kit\" or "
            + "\"Pour-over corner\") and \(lineGuide). No emoji, no exclamation marks, no quotes."
    }
}

/// The structured output of a recap call. Guided generation keeps the model returning a clean tag +
/// line rather than prose we'd have to parse; ``AppleFoundationRecapWriter/recap(from:goal:plan:items:profile:tier:)``
/// then reconciles it into a clean ``WrittenRecap``.
@Generable
public struct RecapDraft {
    @Guide(description: "A short 2-4 word title naming the kit, e.g. 'Rainy-hike kit' or 'Pour-over corner'. No quotes.")
    public var tag: String

    @Guide(description: "One short line in Crumb's warm voice capturing the kit's feeling, grounded in the kept items. No emoji or exclamation marks.")
    public var line: String

    public init(tag: String, line: String) {
        self.tag = tag
        self.line = line
    }
}
