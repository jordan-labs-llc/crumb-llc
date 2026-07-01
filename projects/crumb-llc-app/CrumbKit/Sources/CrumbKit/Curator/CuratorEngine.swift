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

    /// Gift-aware voice: the "why this is you" note, framed as shopping **for** `recipient` when one
    /// is set ("a gift for Mom"), addressing them by name/relationship. `recipient == nil` is the
    /// owner's own voice — identical to ``rationale(for:profile:)``. The default ignores `recipient`
    /// (so a curator with no gift voice still compiles); ``RuleBasedCurator`` overrides it with a
    /// deterministic gift framing, and ``AppleFoundationCurator`` threads it into the model.
    func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?) -> String

    /// Gift- **and** mission-aware voice: the deterministic floor's "why this is you" note, anchored
    /// to `mission` when one is set so it reads on-topic even against a default taste profile ("A
    /// steady pick for “Premium jasmine tea”." rather than a leaning that lands off-topic). `mission
    /// == nil` is identical to ``rationale(for:profile:recipient:)``. The default ignores `mission`
    /// (so a curator with no mission-aware floor still compiles); ``RuleBasedCurator`` overrides it.
    func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?, mission: ShoppingTask?) -> String

    /// Ranks the candidates **and** rewrites each one's rationale into the curator's voice,
    /// returning a ready-to-deal deck plus the ``CuratorTier`` that produced it.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask
    ) async -> CuratedDeck

    /// Refinement-aware curation. `refinement == nil` is identical to the plain
    /// ``curate(_:for:mission:)``.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?
    ) async -> CuratedDeck

    /// **The one true curation entry point** — refinement- AND recipient-aware. Ranks + voices the
    /// deck while honoring a conversational ``RefinementContext`` and, when `recipient` is set,
    /// curating to *their* taste with gift-framed voice. Everything else forwards here, and the app
    /// calls this directly. The card renders `Product.rationale` directly, so a curator only reaches
    /// the screen by returning products whose rationale it has rewritten. The default composes
    /// `rank` + the directive's deterministic shaping + the gift-aware `rationale`;
    /// ``AppleFoundationCurator`` overrides it to use Apple's Foundation Models.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck
}

public extension CuratorEngine {
    /// Default gift voice: ignore `recipient` and speak in the owner's voice. Curators with a real
    /// gift voice (``RuleBasedCurator``, ``AppleFoundationCurator``) override this.
    func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?) -> String {
        rationale(for: product, profile: profile)
    }

    /// Default mission-aware floor: ignore `mission` and speak the recipient-aware line. Curators
    /// with a real mission-aware floor (``RuleBasedCurator``) override this.
    func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?, mission: ShoppingTask?) -> String {
        rationale(for: product, profile: profile, recipient: recipient)
    }

    /// The plain curation entry point — refinement- and recipient-free curation is just the full
    /// path with no context. Kept so every existing call site is unchanged.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask
    ) async -> CuratedDeck {
        await curate(products, for: profile, mission: mission, refinement: nil, recipient: nil)
    }

    /// Refinement-aware curation with no recipient (owner curation). Forwards to the full path.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?
    ) async -> CuratedDeck {
        await curate(products, for: profile, mission: mission, refinement: refinement, recipient: nil)
    }

    /// Default curation: deterministic rank, the directive's deterministic shaping, then
    /// per-product gift-aware seed-voice rationale. Reports ``CuratorTier/ruleBased(_:)`` with no
    /// fallback reason — this is a *chosen* engine, not a degraded one, so the UI stays quiet.
    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        let ranked = await rank(products, for: profile)
        let shaped = RefinementContext.apply(refinement, to: ranked)
        let voiced = shaped.map { $0.withRationale(rationale(for: $0, profile: profile, recipient: recipient, mission: mission)) }
        return CuratedDeck(products: voiced, tier: .ruleBased(nil))
    }
}
