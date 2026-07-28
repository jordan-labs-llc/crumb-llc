import Foundation

/// A deterministic read of how well the kit covers a complete-kit mission's checklist (#67).
///
/// The mission's own `plan` parts are the checklist — it's exactly the list the user saw and edited
/// on the Plan screen ("Lacrosse stick", "Gloves", "Helmet", …) — so completeness needs no separate
/// model field: it checks each part against the products already in the kit.
///
/// A part is *covered* when some kit item names the part's **head noun** — its specific category word
/// ("stick", "helmet", "pads"), the last significant token — not merely the shared mission word
/// ("lacrosse"). That distinction is the whole point: a genuine lacrosse stick covers "Lacrosse
/// stick", while a lacrosse-*print* accessory (which only shares "lacrosse") does not. A single item
/// that reads as a whole-kit **package/bundle** is taken to cover the entire checklist, so one real
/// complete player package reads as complete rather than "missing everything but the package".
///
/// Pure and model-free: same inputs always produce the same read, so it's exhaustively unit-tested
/// and runs identically on the sim/CI.
public struct KitCompleteness: Sendable, Equatable {
    /// Plan parts the kit covers, in plan order.
    public let covered: [String]
    /// Plan parts nothing in the kit covers, in plan order.
    public let missing: [String]

    public init(covered: [String], missing: [String]) {
        self.covered = covered
        self.missing = missing
    }

    /// The kit plausibly covers the whole checklist.
    public var isComplete: Bool { missing.isEmpty }
    /// How many checklist parts there are (covered + missing) — the denominator the UI reads.
    public var requiredCount: Int { covered.count + missing.count }

    /// Assesses `plan` (the checklist) against the products in the kit. Parts with no significant
    /// tokens (all stopwords) are dropped — there's nothing concrete to require. An empty checklist
    /// or empty kit yields all-missing; the caller decides whether to surface it.
    /// `readsRationale` decides whether Crumb's own sentence about a product counts as evidence of
    /// what that product *is*.
    ///
    /// For the cart panel it should: the rationale is prose a curator wrote about this specific item
    /// ("Grippy on wet rock"), and a checkout warning that over-reports missing parts is the worse
    /// error. For a decision Crumb makes on its own it must not, because the deterministic curator —
    /// the floor that runs on every no-model device — voices every card as `A steady pick for
    /// "<mission title>"`. On a goal that names its parts ("lacrosse stick, helmet and gloves") that
    /// sentence contains every head noun in the checklist, so *any* card would appear to cover
    /// *every* part, and a pair of cleats would be kept and filed under "Lacrosse stick".
    public static func assess(
        plan: [String],
        items: [Product],
        readsRationale: Bool = true
    ) -> KitCompleteness {
        let parts = plan.filter { !RuleBasedRelevanceGate.orderedTokens($0).isEmpty }
        guard !parts.isEmpty else { return KitCompleteness(covered: [], missing: []) }

        // One whole-kit package/bundle in the cart covers the entire checklist.
        let hasBundle = items.contains { coversWholeKit($0, readsRationale: readsRationale) }
        let itemTokens = items.map {
            RuleBasedRelevanceGate.tokens(readsRationale ? $0.name + " " + $0.rationale : $0.name)
        }

        var covered: [String] = []
        var missing: [String] = []
        for part in parts {
            if hasBundle || partCovered(part, by: itemTokens) { covered.append(part) }
            else { missing.append(part) }
        }
        return KitCompleteness(covered: covered, missing: missing)
    }

    /// A part is covered when some item's tokens include the part's **head noun** — its last
    /// significant word (the specific category), not the shared mission word. So "Lacrosse stick"
    /// requires "stick": a lacrosse stick covers it, a "Lacrosse Dog Collar" (only "lacrosse") does
    /// not. A part with no significant tokens is treated as covered (nothing concrete to require).
    static func partCovered(_ part: String, by itemTokens: [Set<String>]) -> Bool {
        guard let head = RuleBasedRelevanceGate.orderedTokens(part).last else { return true }
        return itemTokens.contains { $0.contains(head) }
    }

    /// Whether a product reads as a **whole-kit** package/bundle — a strong multi-item signal
    /// ("player package", "gear bundle") — as opposed to a "complete *stick*" component, whose
    /// "complete" says nothing about the kit. Only the strong signals count, so a single complete
    /// component can't masquerade as a full kit. Pure.
    static func coversWholeKit(_ product: Product, readsRationale: Bool = true) -> Bool {
        let text = (readsRationale ? product.name + " " + product.rationale : product.name).lowercased()
        if !RuleBasedRelevanceGate.tokens(text).isDisjoint(with: bundleWords) { return true }
        return bundlePhrases.contains { text.contains($0) }
    }

    /// Single words that, alone, mark a product as a whole-kit bundle. Deliberately excludes the
    /// ambiguous "complete"/"set"/"pack"/"starter"/"kit" (they attach to single components too —
    /// "complete stick", "starter stick"); those are only trusted inside the two-word phrases below.
    static let bundleWords: Set<String> = ["package", "bundle", "loadout"]
    /// Two-word phrases that unambiguously mean a multi-item kit even though their parts are
    /// individually ambiguous.
    static let bundlePhrases: [String] = [
        "complete kit", "full kit", "gear set", "starter set", "player pack", "gear pack",
    ]
}
