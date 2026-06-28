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
        // The curator speaks in the seed voice. If the product's rationale already echoes
        // one of the profile's leanings, let it stand; otherwise add a quiet nod so the
        // copy feels addressed to this user.
        let lowered = product.rationale.lowercased()
        if profile.leanings.contains(where: { lowered.contains(keyword(from: $0)) }) {
            return product.rationale
        }
        if let leaning = profile.leanings.first {
            return "\(product.rationale) Fits your lean toward \(leaning.lowercased())."
        }
        return product.rationale
    }

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
