import Foundation

/// The curation seam: turns a mission into a plan, ranks candidate products against a
/// taste profile, and phrases the "why this is you" rationale.
///
/// The default implementation is the deterministic ``RuleBasedCurator``. A future
/// `FoundationModelsCurator` can sit behind this same protocol using the on-device model
/// (`LanguageModelSession`), gated by availability — see the note in `RuleBasedCurator`.
public protocol CuratorEngine: Sendable {
    /// A short, ordered checklist for the mission (the "parts list" on the Plan screen).
    func plan(for task: ShoppingTask) async -> [String]

    /// Ranks products for a taste profile (best-fit first).
    func rank(_ products: [Product], for profile: TasteProfile) async -> [Product]

    /// The curator's voice copy explaining a product against the profile.
    func rationale(for product: Product, profile: TasteProfile) -> String

    /// Ranks the candidates **and** rewrites each one's rationale into the curator's voice,
    /// returning a ready-to-deal deck plus the ``CuratorTier`` that produced it.
    ///
    /// This is the method the app calls: the card renders `Product.rationale` directly, so a
    /// curator only reaches the screen by returning products whose rationale it has rewritten.
    /// The default implementation composes the existing `rank` + `rationale` (so
    /// ``RuleBasedCurator`` needs no extra code); ``AppleFoundationCurator`` overrides it to
    /// use Apple's Foundation Models.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask
    ) async -> CuratedDeck
}

public extension CuratorEngine {
    /// Default curation: deterministic rank, then per-product seed-voice rationale. Reports
    /// ``CuratorTier/ruleBased(_:)`` with no fallback reason — this is a *chosen* engine, not
    /// a degraded one, so the UI stays quiet about it.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask
    ) async -> CuratedDeck {
        let ranked = await rank(products, for: profile)
        let voiced = ranked.map { $0.withRationale(rationale(for: $0, profile: profile)) }
        return CuratedDeck(products: voiced, tier: .ruleBased(nil))
    }
}
