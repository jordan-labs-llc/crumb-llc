import Foundation

/// Deterministic, offline curator. This is the default ``CuratorEngine`` for the
/// scaffold: it uses the seed `plan`/`rationale` and a simple profile-weighted sort.
///
/// ## Future seam — `FoundationModelsCurator`
/// A later implementation can use Apple's on-device model behind this same protocol:
///
/// ```swift
/// // import FoundationModels
/// // @available(iOS 27, macOS 27, visionOS 27, *)
/// // struct FoundationModelsCurator: CuratorEngine {
/// //     func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
/// //         guard SystemLanguageModel.default.isAvailable else {
/// //             return RuleBasedCurator().rank... // graceful fallback
/// //         }
/// //         let session = LanguageModelSession()
/// //         ... // prompt the model with the profile + candidates
/// //     }
/// // }
/// ```
///
/// Inference is intentionally **not** implemented in this pass.
public struct RuleBasedCurator: CuratorEngine {

    public init() {}

    public func plan(for task: ShoppingTask) async -> [String] {
        task.plan
    }

    public func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        // Stable, deterministic sort: higher score first, ties broken by id so the order
        // never wobbles between runs.
        struct Scored {
            let product: Product
            let score: Double
        }
        let scored: [Scored] = products.map { product in
            Scored(product: product, score: score(product, for: profile))
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.product.id < rhs.product.id
                : lhs.score > rhs.score
        }
        return ranked.map(\.product)
    }

    public func rationale(for product: Product, profile: TasteProfile) -> String {
        rationale(for: product, profile: profile, recipient: nil)
    }

    /// Gift-aware deterministic voice — **this is what renders on the sim/CI** (no model), so it's
    /// the unit-tested floor. When `recipient` is `nil` it's the owner's voice (today's behavior):
    /// the product's rationale stands if it already echoes a leaning, else a quiet "Fits your lean
    /// toward …" nod. When `recipient` is set, the nod is addressed to *them* by name — "Fits Mom's
    /// lean toward …" — and a card that already echoes a leaning gets a light "A gift for Mom." tag,
    /// so every gift card honestly reads as a gift for that person without repeating a full sentence.
    public func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?) -> String {
        let lowered = product.rationale.lowercased()
        let echoesLeaning = profile.leanings.contains { lowered.contains(keyword(from: $0)) }

        guard let recipient else {
            // Owner voice — unchanged.
            if echoesLeaning { return product.rationale }
            if let leaning = profile.leanings.first {
                return "\(product.rationale) Fits your lean toward \(leaning.lowercased())."
            }
            return product.rationale
        }

        // Gift voice — addressed to the recipient by name.
        let name = recipient.name
        if echoesLeaning {
            return "\(product.rationale) A gift for \(name)."
        }
        if let leaning = profile.leanings.first {
            return "\(product.rationale) Fits \(possessive(name))'s lean toward \(leaning.lowercased())."
        }
        return "\(product.rationale) A gift for \(name)."
    }

    /// The base for a possessive — Crumb writes "Mom's", "Dad's", "Alex's". We append "'s" in the
    /// caller, so this just yields the name; kept as a seam in case a name already ends in "s" and we
    /// later want "Chris'" styling. For now every name takes "'s".
    private func possessive(_ name: String) -> String { name }

    // MARK: - Scoring

    /// A deterministic fit score in roughly `0…1.4`.
    private func score(_ product: Product, for profile: TasteProfile) -> Double {
        // Base: normalized rating (4.0…5.0 → 0…1), nudged by review volume confidence.
        let ratingComponent = max(0, (product.rating - 4.0)) // 0…1 for 4.0–5.0
        let reviewConfidence = min(1.0, Double(product.reviews) / 1_500.0) * 0.1

        // Budget fit: a thrifty profile (low budgetComfort) prefers cheaper items; a
        // splurge-happy profile is indifferent. Normalize price across the seed range.
        let priceNorm = min(1.0, NSDecimalNumber(decimal: product.price).doubleValue / 250.0)
        let budgetPenalty = (1.0 - profile.budgetComfort) * priceNorm * 0.3

        // Leaning match: small bonus when the rationale echoes a stated leaning.
        let lowered = product.rationale.lowercased()
        let leaningBonus = profile.leanings
            .contains { lowered.contains(keyword(from: $0)) } ? 0.2 : 0.0

        return ratingComponent + reviewConfidence + leaningBonus - budgetPenalty
    }

    /// The first meaningful word of a leaning, lowercased (e.g. "Merino over synthetic"
    /// → "merino"), used for loose substring matching against rationales.
    private func keyword(from leaning: String) -> String {
        leaning.split(separator: " ").first.map { $0.lowercased() } ?? leaning.lowercased()
    }
}
