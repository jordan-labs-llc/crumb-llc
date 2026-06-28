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
}
