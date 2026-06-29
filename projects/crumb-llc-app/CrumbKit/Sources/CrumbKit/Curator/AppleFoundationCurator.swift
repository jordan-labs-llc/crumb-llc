import Foundation
import FoundationModels

/// The "real" curator voice, built on Apple's Foundation Models. It mirrors how
/// ``LiveUCPClient`` relates to ``MockUCPClient``: ``RuleBasedCurator`` stays the offline
/// default, and this engine is the on-device/server-backed voice that replaces a live
/// product's raw merchant description with Crumb's own "why this is you" copy.
///
/// ## Tiers & degrade order
/// The model both **ranks** the deck (best-fit-for-you first) and **voices** each card. The
/// model is chosen best-first:
///
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — best voice,
///    metered against the user's iCloud quota at no token cost to us. Needs an
///    Apple-Intelligence device, network, and remaining quota. **Compiled in only when the
///    `CRUMB_PCC_ENABLED` flag is set, because touching this type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process** (see the
///    gate in `curate`). On-device is the working primary until that entitlement is granted.
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

    // MARK: Curation

    public func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?
    ) async -> CuratedDeck {
        // The deterministic order: the input we hand the model, the order of the
        // reconciliation tail, and the whole-deck fallback when no tier ranks.
        let baseline = await rule.rank(products, for: profile)
        guard !baseline.isEmpty else { return CuratedDeck(products: [], tier: .onDevice) }

        // Tier 1 — Private Cloud Compute (OS 27+). Gated behind `CRUMB_PCC_ENABLED` because
        // *merely constructing or querying* `PrivateCloudComputeLanguageModel` traps the
        // process (an uncatchable fatal error, NOT a throw) unless the app carries the
        // `com.apple.developer.private-cloud-compute` entitlement. `try?` cannot rescue a
        // trap, so the only safe gate is "don't reference the type unless provisioned."
        // Define the flag *and* add the entitlement together to turn on the best voice tier.
        #if CRUMB_PCC_ENABLED
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
                let session: MakeSession = { LanguageModelSession(model: pcc, instructions: $0) }
                if let voiced = try? await rankAndVoice(baseline, profile, mission, refinement, session: session) {
                    return CuratedDeck(products: voiced, tier: .privateCloud)
                }
                // Ranking probe failed (offline / transient) — fall through to on-device.
            }
        }
        #endif

        // Tier 2 — on-device. Uses the concrete `SystemLanguageModel` session initializer,
        // which (unlike the generic `some LanguageModel` one) is available on macOS 26.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            let session: MakeSession = { LanguageModelSession(model: device, instructions: $0) }
            if let voiced = try? await rankAndVoice(baseline, profile, mission, refinement, session: session) {
                return CuratedDeck(products: voiced, tier: .onDevice)
            }
            return fallback(baseline, profile, refinement, reason: .offlineOrError)
        case let .unavailable(reason):
            return fallback(baseline, profile, refinement, reason: Self.map(reason))
        }
    }

    // MARK: Rank, then voice

    /// Makes a session for a given instructions string. The only version-sensitive step —
    /// the rank/voice loops are API-version agnostic.
    private typealias MakeSession = @Sendable (_ instructions: String) -> LanguageModelSession

    /// The tier's whole job: model-rank the deck (the **probe** — throws if the tier is
    /// unusable, so the caller cascades), then voice every card best-effort over that order.
    /// `refinement`, when present, threads the user's "make it cheaper / warmer / …" ask plus the
    /// running conversation into both the ranking and the voice instructions, so the model honors
    /// it holistically rather than us post-processing its order.
    private func rankAndVoice(
        _ baseline: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        session makeSession: @escaping MakeSession
    ) async throws -> [Product] {
        let ordered = try await modelRankedOrder(baseline, profile, mission, refinement, session: makeSession)
        return await voiceAll(ordered, profile, mission, refinement, session: makeSession)
    }

    /// One guided call asks the model to order the deck best-fit-first; the returned IDs are
    /// reconciled into a total order. Throws when the call fails *or* (for a real multi-item
    /// deck) returns no usable IDs — either way the tier hasn't proven it can rank, so the
    /// caller cascades. A single-item deck can't be mis-ordered, so an empty reply still
    /// proves the tier (reconciliation backfills the one product).
    private func modelRankedOrder(
        _ baseline: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        session makeSession: @escaping MakeSession
    ) async throws -> [Product] {
        // Cap what we send so a big live deck doesn't blow context/latency on the 3B model;
        // products past the cap keep their deterministic order via the reconciliation tail.
        let head = Array(baseline.prefix(Self.rankDeckCap))
        let session = makeSession(Self.rankingInstructions(profile: profile, mission: mission, refinement: refinement))
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
    /// failure just keeps that card's rule-based rationale. Never throws.
    private func voiceAll(
        _ products: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        session makeSession: @escaping MakeSession
    ) async -> [Product] {
        let instructions = Self.instructions(profile: profile, mission: mission, refinement: refinement)
        var out = products
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in products.indices {
                group.addTask {
                    let text = try? await Self.voice(for: products[index], makeSession(instructions))
                    return (index, text)
                }
            }
            for await (index, text) in group {
                out[index] = products[index].withRationale(
                    text ?? rule.rationale(for: products[index], profile: profile)
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
        reason: CuratorTier.Fallback
    ) -> CuratedDeck {
        let shaped = RefinementContext.apply(refinement, to: ranked)
        let voiced = shaped.map { $0.withRationale(rule.rationale(for: $0, profile: profile)) }
        return CuratedDeck(products: voiced, tier: .ruleBased(reason))
    }

    // MARK: Prompt construction

    /// How many candidates we actually send to the model to rank. A guard rail on context and
    /// latency for the on-device 3B model; products past the cap keep their deterministic
    /// order via the reconciliation tail (see ``reconcile(modelIDs:candidates:)``).
    static let rankDeckCap = 25

    /// The shared lede — who Crumb is + this user's taste + the mission. Used verbatim by both
    /// the voice and ranking instructions so the two phases speak to the same persona.
    private static func persona(profile: TasteProfile, mission: ShoppingTask) -> String {
        """
        You are Crumb, a personal shopping curator with a warm, plainspoken, slightly literary \
        voice.

        The user's taste:
        - Vibe: \(profile.vibe.joined(separator: ", "))
        - Leanings: \(profile.leanings.joined(separator: "; "))
        - Budget comfort: \(Self.budgetPhrase(profile.budgetComfort))
        - In their words: "\(profile.signatureLine)"

        Their current mission: "\(mission.title)" — \(mission.subtitle)
        """
    }

    /// The voice instructions: persona + how to write one card's "why this is you" note.
    /// Stable across the deck, so it lives in the session's instructions; only the product
    /// varies per call.
    static func instructions(profile: TasteProfile, mission: ShoppingTask, refinement: RefinementContext? = nil) -> String {
        """
        \(Self.persona(profile: profile, mission: mission))\(Self.refinementClause(refinement))

        You write the one-line "why this is you" note shown under a product the user is \
        considering. Write the rationale so it:
        - is ONE or at most TWO short sentences;
        - speaks to "you" and ties the product to this mission and at least one of their leanings;
        - is specific and honest about THIS product — never invent ratings, reviews, materials, \
        or facts you weren't given;
        - reflects the refinement above when one is present (e.g. lead with value if they asked \
        for cheaper, warmth if they asked for warmer);
        - sounds like a trusted friend with taste, not a marketing blurb. No emoji, no hashtags, \
        no exclamation marks.
        """
    }

    /// The ranking instructions: persona + how to order the deck for *this* user. Honesty
    /// matters more than novelty — on live products ratings/reviews are absent, so the model
    /// must judge fit from taste and mission, not invent quality signals.
    static func rankingInstructions(profile: TasteProfile, mission: ShoppingTask, refinement: RefinementContext? = nil) -> String {
        """
        \(Self.persona(profile: profile, mission: mission))\(Self.refinementClause(refinement))

        You are ordering a deck of candidate products so the best fit for THIS user and \
        mission comes first. Judge fit from their taste, leanings, budget comfort, the \
        mission — and the refinement above when one is present (order cheaper products first if \
        they asked for cheaper, warmer ones first if warmer, and push anything they asked to \
        avoid toward the end). Do not invent ratings, reviews, or facts you weren't given. \
        Return the product IDs in your recommended order, best fit first, using only the IDs \
        provided and including each one exactly once.
        """
    }

    /// A short instructions block describing the user's live refinement (the latest ask plus the
    /// running conversation), appended to both the ranking and voice personas. Empty when there's
    /// no refinement, so plain curation reads exactly as before.
    private static func refinementClause(_ refinement: RefinementContext?) -> String {
        guard let refinement, refinement.directive.isActionable || !refinement.conversation.isEmpty
        else { return "" }
        var lines = ["", "The user is refining this deck. Honor what they asked:"]
        let directive = refinement.directive
        if !directive.emphasis.isEmpty { lines.append("- Emphasis: \(directive.emphasis)") }
        switch directive.priceDirection {
        case .cheaper: lines.append("- Price: prefer cheaper options.")
        case .pricier: lines.append("- Price: they're happy to spend more for better.")
        case .none: break
        }
        if !directive.removeHints.isEmpty {
            lines.append("- Avoid / de-emphasize: \(directive.removeHints.joined(separator: ", ")).")
        }
        if refinement.conversation.count > 1 {
            let earlier = refinement.conversation.dropLast().joined(separator: "; ")
            lines.append("- Earlier refinements still apply: \(earlier).")
        }
        return lines.joined(separator: "\n")
    }

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

    private static func budgetPhrase(_ comfort: Double) -> String {
        switch comfort {
        case ..<0.34: return "thrifty — values getting it right for less"
        case ..<0.67: return "balanced — will pay for quality that lasts"
        default: return "splurge-happy — happy to invest in the best"
        }
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
