import Foundation
import FoundationModels

/// The "real" curator voice, built on Apple's Foundation Models. It mirrors how
/// ``LiveUCPClient`` relates to ``MockUCPClient``: ``RuleBasedCurator`` stays the offline
/// default, and this engine is the on-device/server-backed voice that replaces a live
/// product's raw merchant description with Crumb's own "why this is you" copy.
///
/// ## Dynamic sessions (Xcode 27)
/// This seam is the **reference adoption** of Apple's composable dynamic-session API. Its old
/// hand-built instruction *strings* are gone: ranking and voicing each compose
/// ``CrumbPersona`` / ``TasteBlock`` / ``MissionBlock`` / ``RefinementClause`` into a
/// ``DynamicInstructions`` value, wrapped in a `LanguageModelSession.Profile` that also declares
/// the seam's tuning and context policy (`.temperature`, `.reasoningLevel`, `.maximumResponseTokens`,
/// `.historyTransform`, `.transcriptErrorHandlingPolicy` — see ``CrumbContext``). The model is
/// selected on the *profile* (`.model(_:)`), so the tier cascade just swaps which model the same
/// profile builders receive.
///
/// ## Tiers & degrade order
/// The model both **ranks** the deck (best-fit-for-you first) and **voices** each card. The
/// model is chosen best-first:
///
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — best voice,
///    metered against the user's iCloud quota at no token cost to us. **Compiled in only when the
///    `CRUMB_PCC_ENABLED` flag is set, because touching this type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process** (see the
///    gate in `curate`). When enabled it gets `.reasoningLevel(.deep)`; on-device is the working
///    primary until that entitlement is granted.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, lower quality, no entitlement.
/// 3. **Rule-based** — the deterministic ``RuleBasedCurator`` order + seed voice, used when
///    neither model is usable.
///
/// ## What the model does vs. the deterministic floor
/// On live products `RuleBasedCurator.score` is weak — rating/reviews are 0, so the order
/// leans only on leanings/budget. So when a model tier is up, **the model picks the order**:
/// one guided call returns the candidate IDs best-fit-first, which we reconcile into a total
/// order (see ``reconcile(modelIDs:candidates:)``). The deterministic ``RuleBasedCurator/rank``
/// stays the input order we feed the model, the order of the reconciliation tail, and the
/// whole-deck fallback when no tier ranks.
///
/// ## How a tier proves itself
/// The **ranking call is the tier probe**: if it throws (offline / system not ready) or
/// returns no usable IDs, curation cascades to the next tier. Once ranking succeeds the tier
/// is proven, and the per-product voice rewrite is then fully best-effort — a later
/// per-product failure just leaves that one card on the rule-based rationale, never blanking
/// a card or downgrading the whole deck.
public struct AppleFoundationCurator: CuratorEngine {

    /// Ranking, plan, and the fallback rationale all come from the deterministic engine.
    private let rule = RuleBasedCurator()

    public init() {}

    // MARK: CuratorEngine (delegated)

    public func plan(for task: ShoppingTask) async -> [String] {
        await rule.plan(for: task)
    }

    public func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        await rule.rank(products, for: profile)
    }

    public func rationale(for product: Product, profile: TasteProfile) -> String {
        rule.rationale(for: product, profile: profile)
    }

    public func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?) -> String {
        rule.rationale(for: product, profile: profile, recipient: recipient)
    }

    // MARK: Curation

    public func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        // The deterministic order: the input we hand the model, the order of the
        // reconciliation tail, and the whole-deck fallback when no tier ranks.
        let baseline = await rule.rank(products, for: profile)
        guard !baseline.isEmpty else { return CuratedDeck(products: [], tier: .onDevice) }

        // Tier 1 — Private Cloud Compute. Gated behind `CRUMB_PCC_ENABLED` because *merely
        // constructing or querying* `PrivateCloudComputeLanguageModel` traps the process (an
        // uncatchable fatal error, NOT a throw) unless the app carries the
        // `com.apple.developer.private-cloud-compute` entitlement. `try?` cannot rescue a trap, so
        // the only safe gate is "don't reference the type unless provisioned." Define the flag
        // *and* add the entitlement together to turn on the best voice tier.
        #if CRUMB_PCC_ENABLED
        let pcc = PrivateCloudComputeLanguageModel()
        if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
            if let voiced = try? await rankAndVoice(baseline, profile, mission, refinement, recipient, model: pcc, deepReasoning: true) {
                return CuratedDeck(products: voiced, tier: .privateCloud)
            }
            // Ranking probe failed (offline / transient) — fall through to on-device.
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            if let voiced = try? await rankAndVoice(baseline, profile, mission, refinement, recipient, model: device, deepReasoning: false) {
                return CuratedDeck(products: voiced, tier: .onDevice)
            }
            return fallback(baseline, profile, refinement, recipient, reason: .offlineOrError)
        case let .unavailable(reason):
            return fallback(baseline, profile, refinement, recipient, reason: Self.map(reason))
        }
    }

    // MARK: Rank, then voice

    /// The tier's whole job: model-rank the deck (the **probe** — throws if the tier is
    /// unusable, so the caller cascades), then voice every card best-effort over that order.
    /// `refinement`, when present, threads the user's "make it cheaper / warmer / …" ask plus the
    /// running conversation into both the ranking and the voice instructions (via
    /// ``RefinementClause``), so the model honors it holistically rather than us post-processing its
    /// order. `model` is whichever tier proved available; `deepReasoning` lifts both phases to
    /// `.reasoningLevel(.deep)` for the server tier.
    private func rankAndVoice<M: LanguageModel>(
        _ baseline: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async throws -> [Product] {
        let ordered = try await modelRankedOrder(baseline, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning)
        return await voiceAll(ordered, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning)
    }

    /// One guided call asks the model to order the deck best-fit-first; the returned IDs are
    /// reconciled into a total order. Throws when the call fails *or* (for a real multi-item
    /// deck) returns no usable IDs — either way the tier hasn't proven it can rank, so the
    /// caller cascades. A single-item deck can't be mis-ordered, so an empty reply still
    /// proves the tier (reconciliation backfills the one product).
    private func modelRankedOrder<M: LanguageModel>(
        _ baseline: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async throws -> [Product] {
        // Cap what we send so a big live deck doesn't blow context/latency on the 3B model;
        // products past the cap keep their deterministic order via the reconciliation tail.
        let head = Array(baseline.prefix(Self.rankDeckCap))
        let session = Self.rankSession(profile: profile, mission: mission, refinement: refinement, recipient: recipient, model: model, deepReasoning: deepReasoning)
        // The response bound + context policy live on the profile (see `rankSession`), not as an
        // inline `GenerationOptions` band-aid.
        let response = try await session.respond(
            to: Self.rankPrompt(for: head),
            generating: RankedOrder.self
        )
        let ids = response.content.productIDs
        let candidateIDs = Set(baseline.map(\.id))
        let usable = Set(ids).intersection(candidateIDs)
        if baseline.count > 1 && usable.isEmpty { throw CuratorRankError.noUsableIDs }
        return Self.reconcile(modelIDs: ids, candidates: baseline)
    }

    /// Folds the model's ID order back onto the candidate set into a **total** order that
    /// never drops or duplicates a product: each valid, first-seen model ID in its given
    /// order, then any candidate the model omitted (or that fell past the rank cap) appended
    /// in the deterministic `candidates` order. Pure and model-free — this is the unit-tested
    /// guarantee behind the model call.
    static func reconcile(modelIDs: [String], candidates: [Product]) -> [Product] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [Product] = []
        for id in modelIDs {
            guard let product = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(product)
        }
        for product in candidates where !seen.contains(product.id) {
            ordered.append(product)
        }
        return ordered
    }

    /// Voices every card best-effort: the tier is already proven by ranking, so a per-product
    /// failure just keeps that card's rule-based rationale. Each card gets its own fresh session
    /// (no shared transcript — products must not bleed into one another's voice), built from the
    /// same voice profile. Never throws.
    private func voiceAll<M: LanguageModel>(
        _ products: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async -> [Product] {
        var out = products
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in products.indices {
                group.addTask {
                    let session = Self.voiceSession(profile: profile, mission: mission, refinement: refinement, recipient: recipient, model: model, deepReasoning: deepReasoning)
                    let text = try? await Self.voice(for: products[index], session)
                    return (index, text)
                }
            }
            for await (index, text) in group {
                out[index] = products[index].withRationale(
                    text ?? rule.rationale(for: products[index], profile: profile, recipient: recipient)
                )
            }
        }
        return out
    }

    /// One guided generation: a short, distinctive curator-voice rationale for `product`.
    private static func voice(
        for product: Product,
        _ session: LanguageModelSession
    ) async throws -> String {
        let response = try await session.respond(
            to: prompt(for: product),
            generating: CuratorVoice.self
        )
        let text = response.content.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CuratorVoiceError.emptyRationale }
        return text
    }

    /// The whole-deck fallback when no model tier ranks. Applies the refinement's *structured*
    /// asks deterministically (``RefinementContext/apply(_:to:)`` — price lean, emphasis boost,
    /// remove demote) so a degraded tier still visibly honors "make it cheaper" before voicing in
    /// the seed voice.
    private func fallback(
        _ ranked: [Product],
        _ profile: TasteProfile,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        reason: CuratorTier.Fallback
    ) -> CuratedDeck {
        let shaped = RefinementContext.apply(refinement, to: ranked)
        let voiced = shaped.map { $0.withRationale(rule.rationale(for: $0, profile: profile, recipient: recipient)) }
        return CuratedDeck(products: voiced, tier: .ruleBased(reason))
    }

    // MARK: Sessions (dynamic instructions + profile)

    /// How many candidates we actually send to the model to rank. A guard rail on context and
    /// latency for the on-device 3B model; products past the cap keep their deterministic
    /// order via the reconciliation tail (see ``reconcile(modelIDs:candidates:)``).
    static let rankDeckCap = 25

    /// Curator tuning — chosen per phase. Ranking is a judgment task that wants a stable order, so
    /// it runs cooler; voicing is short creative copy, so it runs warmer. The response bounds keep
    /// each generation well under the 4096-token window (see ``CrumbContext``) without truncating a
    /// real ID list or a two-sentence rationale.
    ///
    /// `.reasoningLevel` is applied ONLY on the deep-reasoning (Private Cloud Compute) tier: the
    /// on-device `SystemLanguageModel` does not support reasoning and *throws* if a level is set, so
    /// the on-device profile omits it and leans on temperature alone (learned at runtime on the sim).
    static let rankTemperature = 0.45
    static let voiceTemperature = 0.7
    static let rankMaxResponseTokens = 512
    static let voiceMaxResponseTokens = 200

    /// Builds the ranking session: ``CuratorRankInstructions`` in a profile that selects the tier's
    /// model and declares the ranking tuning + context policy.
    static func rankSession<M: LanguageModel>(
        profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) -> LanguageModelSession {
        let instructions = CuratorRankInstructions(profile: profile, mission: mission, refinement: refinement, recipient: recipient)
        let base = LanguageModelSession.Profile { instructions }
            .model(model)
            .temperature(rankTemperature)
            .maximumResponseTokens(rankMaxResponseTokens)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        // Reasoning is a server-tier capability only — adding it on-device throws.
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
    }

    /// Builds a per-product voice session: ``CuratorVoiceInstructions`` in a profile that selects
    /// the tier's model and declares the voice tuning + context policy.
    static func voiceSession<M: LanguageModel>(
        profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) -> LanguageModelSession {
        let instructions = CuratorVoiceInstructions(profile: profile, mission: mission, refinement: refinement, recipient: recipient)
        let base = LanguageModelSession.Profile { instructions }
            .model(model)
            .temperature(voiceTemperature)
            .maximumResponseTokens(voiceMaxResponseTokens)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        // Reasoning is a server-tier capability only — adding it on-device throws.
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
    }

    // MARK: Prompt construction

    /// The deck the model orders: one terse line per candidate so the small model can hold the
    /// whole set at once. IDs are echoed back as the ranking output.
    static func rankPrompt(for products: [Product]) -> String {
        var lines = ["Candidate products:"]
        for product in products {
            var line = "- [\(product.id)] \(product.name) — \(product.shop.name) — \(product.price) USD"
            let description = product.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty {
                line += " — \(description.prefix(140))"
            }
            lines.append(line)
        }
        lines.append("Return the product IDs ordered best fit first for this user and mission.")
        return lines.joined(separator: "\n")
    }

    static func prompt(for product: Product) -> String {
        var lines = [
            "Product: \(product.name)",
            "Shop: \(product.shop.name)",
            "Price: \(product.price) USD",
        ]
        let description = product.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            lines.append("Merchant description: \(description)")
        }
        lines.append("Write Crumb's rationale for why this fits the user and their mission.")
        return lines.joined(separator: "\n")
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> CuratorTier.Fallback {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .offlineOrError
        }
    }
}

// MARK: - Dynamic instructions

/// The ranking instructions: persona + taste + mission + (optional) refinement + how to order the
/// deck for *this* user. Honesty matters more than novelty — on live products ratings/reviews are
/// absent, so the model must judge fit from taste and mission, not invent quality signals.
struct CuratorRankInstructions: DynamicInstructions {
    let profile: TasteProfile
    let mission: ShoppingTask
    let refinement: RefinementContext?
    let recipient: RecipientRef?

    var body: some DynamicInstructions {
        CrumbPersona(recipient: recipient)
        TasteBlock(profile: profile, recipient: recipient, includeBudget: true)
        MissionBlock(mission: mission)
        RefinementClause(refinement: refinement)
        Instructions(Self.rankGuide(recipient: recipient))
    }

    /// The "how to order the deck" guidance. Pure — unit-tested.
    static func rankGuide(recipient: RecipientRef?) -> String {
        let subject = recipient.map { "\($0.name) (the gift's recipient)" } ?? "THIS user"
        return """
        You are ordering a deck of candidate products so the best fit for \(subject) and the \
        mission comes first. Judge fit from their taste, leanings, budget comfort, the \
        mission — and the refinement above when one is present (order cheaper products first if \
        they asked for cheaper, warmer ones first if warmer, and push anything they asked to \
        avoid toward the end). Do not invent ratings, reviews, or facts you weren't given. \
        Return the product IDs in your recommended order, best fit first, using only the IDs \
        provided and including each one exactly once.
        """
    }
}

/// The voice instructions: persona + taste + mission + (optional) refinement + how to write one
/// card's "why this is you" note.
struct CuratorVoiceInstructions: DynamicInstructions {
    let profile: TasteProfile
    let mission: ShoppingTask
    let refinement: RefinementContext?
    let recipient: RecipientRef?

    var body: some DynamicInstructions {
        CrumbPersona(recipient: recipient)
        TasteBlock(profile: profile, recipient: recipient, includeBudget: true)
        MissionBlock(mission: mission)
        RefinementClause(refinement: refinement)
        Instructions(Self.voiceGuide(recipient: recipient))
    }

    /// The "how to write the rationale" guidance. Pure — unit-tested.
    static func voiceGuide(recipient: RecipientRef?) -> String {
        let voiceLine = recipient.map { rec in
            "- frames the product as a gift for \(rec.name) and ties it to their taste (you may name \(rec.name) once);"
        } ?? "- speaks to \"you\" and ties the product to this mission and at least one of their leanings;"
        return """
        You write the one-line "why this is you" note shown under a product being considered. \
        Write the rationale so it:
        - is ONE or at most TWO short sentences;
        \(voiceLine)
        - is specific and honest about THIS product — never invent ratings, reviews, materials, \
        or facts you weren't given;
        - reflects the refinement above when one is present (e.g. lead with value if they asked \
        for cheaper, warmth if they asked for warmer);
        - sounds like a trusted friend with taste, not a marketing blurb. No emoji, no hashtags, \
        no exclamation marks.
        """
    }
}

/// The structured output of one curation call. A single guided field keeps the model on a
/// short, well-formed rationale (Apple's guided generation enforces the shape).
@Generable
struct CuratorVoice {
    @Guide(description: "One or two short sentences, second person, in Crumb's curator voice.")
    var rationale: String
}

enum CuratorVoiceError: Error {
    case emptyRationale
}

/// The structured output of the ranking call: the candidate IDs in best-fit order. Guided
/// generation keeps the model returning a clean list of IDs rather than prose we'd have to
/// parse; `reconcile` then makes the order total and drop/dupe-free.
@Generable
struct RankedOrder {
    @Guide(description: "The given product IDs, ordered best fit first, each ID included exactly once.")
    var productIDs: [String]
}

enum CuratorRankError: Error {
    /// The model returned no IDs that match the deck — for a real multi-item deck this means
    /// the tier didn't actually rank, so the caller cascades to the next tier.
    case noUsableIDs
}
