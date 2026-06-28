import Foundation
import FoundationModels

/// The "real" curator voice, built on Apple's Foundation Models. It mirrors how
/// ``LiveUCPClient`` relates to ``MockUCPClient``: ``RuleBasedCurator`` stays the offline
/// default, and this engine is the on-device/server-backed voice that replaces a live
/// product's raw merchant description with Crumb's own "why this is you" copy.
///
/// ## Tiers & degrade order
/// Ranking is deterministic (delegated to ``RuleBasedCurator``); only the *rationale* is
/// model-written, one guided call per product. The model is chosen best-first:
///
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — best voice,
///    metered against the user's iCloud quota at no token cost to us. Needs an
///    Apple-Intelligence device, network, and remaining quota. **Compiled in only when the
///    `CRUMB_PCC_ENABLED` flag is set, because touching this type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process** (see the
///    gate in `curate`). On-device is the working primary until that entitlement is granted.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, lower quality, no entitlement.
/// 3. **Rule-based** — the deterministic seed voice, used when neither model is usable.
///
/// A tier "proves" itself on the first product call: if that throws (offline / system not
/// ready), curation cascades to the next tier. Once a tier is proven, a later per-product
/// failure just leaves that one card on the rule-based rationale — one hiccup never blanks
/// a card or downgrades the whole deck.
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
        mission: ShoppingTask
    ) async -> CuratedDeck {
        let ranked = await rule.rank(products, for: profile)
        guard !ranked.isEmpty else { return CuratedDeck(products: [], tier: .onDevice) }

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
                let session: VoiceSession = { LanguageModelSession(model: pcc, instructions: $0) }
                if let voiced = try? await rewrite(ranked, profile, mission, session: session) {
                    return CuratedDeck(products: voiced, tier: .privateCloud)
                }
                // First call failed (offline / transient) — fall through to on-device.
            }
        }
        #endif

        // Tier 2 — on-device. Uses the concrete `SystemLanguageModel` session initializer,
        // which (unlike the generic `some LanguageModel` one) is available on macOS 26.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            let session: VoiceSession = { LanguageModelSession(model: device, instructions: $0) }
            if let voiced = try? await rewrite(ranked, profile, mission, session: session) {
                return CuratedDeck(products: voiced, tier: .onDevice)
            }
            return fallback(ranked, profile, reason: .offlineOrError)
        case let .unavailable(reason):
            return fallback(ranked, profile, reason: Self.map(reason))
        }
    }

    // MARK: Rationale rewriting

    /// Makes a session for a given instructions string. The only version-sensitive step —
    /// the rest of the rewrite loop is API-version agnostic.
    private typealias VoiceSession = @Sendable (_ instructions: String) -> LanguageModelSession

    /// Rewrites every product's rationale, throwing if the **first** call fails (so the
    /// caller can cascade to the next tier). Later per-product failures keep the rule-based
    /// rationale for that one product — one hiccup never blanks a card.
    private func rewrite(
        _ ranked: [Product],
        _ profile: TasteProfile,
        _ mission: ShoppingTask,
        session makeSession: @escaping VoiceSession
    ) async throws -> [Product] {
        let instructions = Self.instructions(profile: profile, mission: mission)

        // Probe the first product; a throw here means the tier is unusable → cascade.
        var out = ranked
        out[0] = ranked[0].withRationale(
            try await Self.voice(for: ranked[0], makeSession(instructions))
        )

        guard ranked.count > 1 else { return out }

        // Remaining products in parallel; a failure leaves the seed/rule-based rationale.
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in ranked.indices.dropFirst() {
                group.addTask {
                    let text = try? await Self.voice(
                        for: ranked[index], makeSession(instructions)
                    )
                    return (index, text)
                }
            }
            for await (index, text) in group {
                out[index] = ranked[index].withRationale(
                    text ?? rule.rationale(for: ranked[index], profile: profile)
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

    private func fallback(
        _ ranked: [Product],
        _ profile: TasteProfile,
        reason: CuratorTier.Fallback
    ) -> CuratedDeck {
        let voiced = ranked.map { $0.withRationale(rule.rationale(for: $0, profile: profile)) }
        return CuratedDeck(products: voiced, tier: .ruleBased(reason))
    }

    // MARK: Prompt construction

    /// The curator persona + this user's taste + the mission. Stable across the deck, so it
    /// lives in the session's instructions; only the product varies per call.
    static func instructions(profile: TasteProfile, mission: ShoppingTask) -> String {
        """
        You are Crumb, a personal shopping curator with a warm, plainspoken, slightly literary \
        voice. You write the one-line "why this is you" note shown under a product the user is \
        considering.

        The user's taste:
        - Vibe: \(profile.vibe.joined(separator: ", "))
        - Leanings: \(profile.leanings.joined(separator: "; "))
        - Budget comfort: \(Self.budgetPhrase(profile.budgetComfort))
        - In their words: "\(profile.signatureLine)"

        Their current mission: "\(mission.title)" — \(mission.subtitle)

        Write the rationale so it:
        - is ONE or at most TWO short sentences;
        - speaks to "you" and ties the product to this mission and at least one of their leanings;
        - is specific and honest about THIS product — never invent ratings, reviews, materials, \
        or facts you weren't given;
        - sounds like a trusted friend with taste, not a marketing blurb. No emoji, no hashtags, \
        no exclamation marks.
        """
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
