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

    /// The mission-aware floor (#33) must reach the ``RuleBasedCurator`` — without this override the
    /// protocol default would forward to the mission-*agnostic* `recipient:` overload, dropping the
    /// mission and voicing "…your lean toward merino…" on a tea card. This is the line the app's
    /// streamed floor (`AppModel`) renders before the model-voiced deck settles.
    public func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?, mission: ShoppingTask?) -> String {
        rule.rationale(for: product, profile: profile, recipient: recipient, mission: mission)
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
        let baseline = rule.rank(products, for: profile, mission: mission)
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
            return fallback(baseline, profile, mission, refinement, recipient, reason: .offlineOrError)
        case let .unavailable(reason):
            return fallback(baseline, profile, mission, refinement, recipient, reason: Self.map(reason))
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

    /// Orders the deck best-fit-first with the model, then reconciles into a total order.
    ///
    /// Rather than send the whole deck in one call — which overflows the on-device 4096-token
    /// context on a real live deck and drops the *entire* deck to the deterministic floor — it ranks
    /// in a **map-reduce tournament**: split into reasonable-size chunks, rank each concurrently (a
    /// small, reliable call), promote the top of each, and recurse on the promoted field until it
    /// fits a single chunk. The survivors come out ordered best-first, the also-rans (in their
    /// chunk-ranked order) behind them; ``reconcile(modelIDs:candidates:)`` then appends anything
    /// past the cap in deterministic order.
    ///
    /// Throws only when the model truly can't rank (every first-level chunk call fails) — the same
    /// tier-probe contract as the old single call, so the caller still cascades to the floor.
    private func modelRankedOrder<M: LanguageModel>(
        _ baseline: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async throws -> [Product] {
        // Cap what we consider so a huge live deck doesn't spawn unbounded chunk calls; products
        // past the cap keep their deterministic order via the reconciliation tail.
        let head = Array(baseline.prefix(Self.rankDeckCap))
        let ordered = try await tournamentRank(head, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning)
        let reconciled = Self.reconcile(modelIDs: ordered.map(\.id), candidates: baseline)
        return RuleBasedCurator().rank(reconciled, for: profile, mission: mission)
    }

    /// The recursive map-reduce ranker. A pool that already fits one chunk is a single ranking call;
    /// a larger pool is split, each chunk ranked concurrently, the top ``rankAdvancePerChunk`` of
    /// each promoted, and the promoted field ranked again — until it fits one chunk. A chunk whose
    /// call fails keeps its deterministic input order; a transient failure in a *reduce* round keeps
    /// the promoted order rather than discarding partial work. Only an all-fail first split throws.
    private func tournamentRank<M: LanguageModel>(
        _ pool: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async throws -> [Product] {
        guard pool.count > Self.rankChunkSize else {
            return try await rankOnce(pool, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning)
        }
        let chunks = Self.chunked(pool, size: Self.rankChunkSize)
        let ranked = try await mapRankChunks(chunks, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning)
        let (winners, losers) = Self.advance(ranked, keep: Self.rankAdvancePerChunk)
        let top = (try? await tournamentRank(winners, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning)) ?? winners
        return top + losers
    }

    /// Ranks the chunks concurrently. A chunk whose call fails keeps its deterministic input order,
    /// so one transient failure doesn't sink the rank; but if EVERY chunk fails the model can't rank
    /// at all → throw so ``curate(_:for:mission:refinement:recipient:)`` falls back to the floor.
    private func mapRankChunks<M: LanguageModel>(
        _ chunks: [[Product]],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async throws -> [[Product]] {
        let ranked = await withTaskGroup(of: (Int, [Product]?).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    (index, try? await rankOnce(chunk, profile, mission, refinement, recipient, model: model, deepReasoning: deepReasoning))
                }
            }
            var out = [[Product]?](repeating: nil, count: chunks.count)
            for await (index, result) in group { out[index] = result }
            return out
        }
        guard ranked.contains(where: { $0 != nil }) else { throw CuratorRankError.noUsableIDs }
        // A failed chunk keeps its deterministic input order.
        return zip(chunks, ranked).map { chunk, result in result ?? chunk }
    }

    /// One guided ranking call over a single set (a chunk, or a whole small deck): returns the set
    /// ordered best-first, reconciled so every product is present exactly once even if the model
    /// omits or repeats an id. Throws when the call fails or (for a multi-item set) returns no usable
    /// ids. The response bound + context policy live on the session profile (see ``rankSession``).
    private func rankOnce<M: LanguageModel>(
        _ products: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        model: M,
        deepReasoning: Bool
    ) async throws -> [Product] {
        let session = Self.rankSession(profile: profile, mission: mission, refinement: refinement, recipient: recipient, model: model, deepReasoning: deepReasoning)
        let response = try await session.respond(
            to: Self.rankPrompt(for: products),
            generating: RankedOrder.self
        )
        let ids = response.content.productIDs
        let usable = Set(ids).intersection(Set(products.map(\.id)))
        if products.count > 1 && usable.isEmpty { throw CuratorRankError.noUsableIDs }
        return Self.reconcile(modelIDs: ids, candidates: products)
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

    /// Splits `products` into consecutive chunks of at most `size` (the last may be smaller),
    /// preserving order — the map step of the ranking tournament. Pure and unit-tested.
    static func chunked(_ products: [Product], size: Int) -> [[Product]] {
        guard size > 0 else { return products.isEmpty ? [] : [products] }
        return stride(from: 0, to: products.count, by: size).map {
            Array(products[$0 ..< Swift.min($0 + size, products.count)])
        }
    }

    /// Promotes the top `keep` of each ranked chunk into `winners` (the field for the next
    /// tournament round) and gathers the rest into `losers` (kept in their chunk-ranked order, to sit
    /// behind the finalists). Pure and unit-tested — the reduce step's promotion rule.
    static func advance(_ rankedChunks: [[Product]], keep: Int) -> (winners: [Product], losers: [Product]) {
        var winners: [Product] = []
        var losers: [Product] = []
        for chunk in rankedChunks {
            winners.append(contentsOf: chunk.prefix(keep))
            losers.append(contentsOf: chunk.dropFirst(keep))
        }
        return (winners, losers)
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
                    text ?? rule.rationale(for: products[index], profile: profile, recipient: recipient, mission: mission)
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
        _ mission: ShoppingTask,
        _ refinement: RefinementContext?,
        _ recipient: RecipientRef?,
        reason: CuratorTier.Fallback
    ) -> CuratedDeck {
        let shaped = RefinementContext.apply(refinement, to: ranked)
        let voiced = shaped.map { $0.withRationale(rule.rationale(for: $0, profile: profile, recipient: recipient, mission: mission)) }
        return CuratedDeck(products: voiced, tier: .ruleBased(reason))
    }

    // MARK: Sessions (dynamic instructions + profile)

    /// How many candidates we actually send to the model to rank. A guard rail on context and
    /// latency for the on-device 3B model; products past the cap keep their deterministic
    /// order via the reconciliation tail (see ``reconcile(modelIDs:candidates:)``).
    static let rankDeckCap = 25

    /// Map-reduce ranking (see ``modelRankedOrder``): the largest set sent to the model in one
    /// ranking call. Small enough to stay well under the on-device 4096-token context — a whole-deck
    /// call overflowed it and dropped the deck to the deterministic floor; a chunk this size ranks
    /// reliably (proven on the sim).
    static let rankChunkSize = 6
    /// How many of each ranked chunk advance to the next tournament round. Strictly less than
    /// ``rankChunkSize`` so the promoted field always shrinks and the tournament converges; 2 keeps a
    /// strong chunk's runner-up in contention rather than crowning only its winner.
    static let rankAdvancePerChunk = 2

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
        For premium food or beverage missions, prefer specialty merchants and concrete quality \
        signals over generic, sample, bulk, or low-trust matches. \
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
        - for premium tea missions, names concrete quality signals when present (loose leaf, \
        whole leaf, jasmine pearls, organic, origin/scenting, or specialty tea merchant) and \
        honestly calls out sample/budget/cross-border tradeoffs when those are the visible facts;
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
