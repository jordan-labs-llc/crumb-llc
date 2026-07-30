import Foundation

/// Which part of a mission a candidate belongs to — the answer that tells an *alternative* from a
/// different piece of the same errand.
///
/// A kit mission's deck is one globally fit-ranked union of several searches. Read as a flat list it
/// says the brew mat is the cheaper option next to the beans, which is confidently wrong in a way a
/// price ladder never was. Everything that presents two candidates as choices — the foils beside a
/// recommendation, the part-at-a-time question order — needs to know that the mat and the beans are
/// not the same decision.
///
/// Two signals answer that, and both are load-bearing:
///
/// - **The plan's own words.** A part is a phrase the person read and could edit ("Gooseneck
///   kettle"), and its head noun is the specific category. A product whose *name* carries that head
///   noun belongs to that part. This is the stronger signal wherever it applies, because it is the
///   vocabulary the person actually chose.
/// - **Provenance** — the search that found the product, threaded from the gather. This is the only
///   signal for anything outside the plan, and the orchestrator is deliberately instructed to reach
///   beyond it ("dorm room refresh" → a desk lamp nobody listed). It is also the only signal when a
///   catalog names things nothing like the plan does.
///
/// The plan is consulted first and provenance second, so a search that returned a spread of
/// categories — every part of the mock catalog answers every one of its mission's queries — is
/// sorted by what the products *are* rather than filed wholesale under whichever query raced first.
/// A product neither signal can place gets no part: callers treat that as "don't know", which costs
/// a foil rather than inventing a wrong one.
///
/// Pure and model-free.
public enum MissionPartAttribution {

    /// The part `product` belongs to, or `nil` when neither signal can place it.
    ///
    /// `plan` is the checklist in plan order (``MissionPlanPart/label``); `provenance` is the label
    /// the gather attributed this product to, if any.
    public static func part(of product: Product, plan: [String], provenance: String?) -> String? {
        // `product.name` only — deliberately never the rationale. The deterministic curator voices
        // every card as `A steady pick for "<mission title>"`, and on a goal that names its parts
        // that sentence contains every head noun in the checklist, so reading it would file every
        // card under the first part. Same trap ``KitCompleteness`` documents for auto-keep.
        let tokens = [RuleBasedRelevanceGate.tokens(product.name)]
        // A part with no significant tokens is skipped, not matched: `partCovered` reports it as
        // covered by anything (there is nothing concrete to require), which would make an all-
        // stopword part swallow the whole deck.
        let named = plan.first {
            !RuleBasedRelevanceGate.orderedTokens($0).isEmpty && KitCompleteness.partCovered($0, by: tokens)
        }
        return named ?? provenance
    }

    /// The part of every candidate, keyed by product id — the whole deck resolved in one pass.
    /// Products neither signal places are absent rather than mapped to a placeholder.
    public static func parts(
        of products: [Product],
        plan: [String],
        provenance: [Product.ID: String]
    ) -> [Product.ID: String] {
        var resolved: [Product.ID: String] = [:]
        for product in products {
            resolved[product.id] = part(of: product, plan: plan, provenance: provenance[product.id])
        }
        return resolved.compactMapValues { $0 }
    }

    /// Whether an attribution actually divides `products` — whether more than one part is
    /// represented at all.
    ///
    /// This is the precondition for reading "same part" as "these are alternatives". A mission whose
    /// whole pool resolves to one part has an attribution that distinguishes nothing, and the
    /// commonest way to get there is not exotic: the deterministic planner frames almost every typed
    /// goal as a **single** part ("Set up my pour-over corner" → one part, one query), so every
    /// candidate it gathers shares one provenance. Comparing across that bucket puts the brew mat
    /// beside the kettle as the cheaper option — the exact mistake attribution exists to prevent,
    /// dressed up as evidence. Judged over the mission's whole candidate set rather than what is
    /// left undecided, so a kit narrowing down to its last open part keeps its alternatives.
    public static func isPartitioned(
        _ products: [Product],
        plan: [String],
        provenance: [Product.ID: String]
    ) -> Bool {
        var seen: Set<String> = []
        for product in products {
            guard let part = part(of: product, plan: plan, provenance: provenance[product.id])
            else { continue }
            seen.insert(part)
            if seen.count > 1 { return true }
        }
        return false
    }

    /// The candidates that are genuine alternatives to `product`: the ones the same part placed,
    /// in the order given (the curator's ranking), never including `product` itself.
    ///
    /// An unplaceable `product` has no alternatives — that is the conservative half of the contract.
    /// Offering the kettle as "Cheaper" beside the beans is worse than offering nothing.
    public static func peers(
        of product: Product,
        among candidates: [Product],
        plan: [String],
        provenance: [Product.ID: String]
    ) -> [Product] {
        guard let part = part(of: product, plan: plan, provenance: provenance[product.id]) else {
            return []
        }
        return candidates.filter {
            $0.id != product.id
                && Self.part(of: $0, plan: plan, provenance: provenance[$0.id]) == part
        }
    }
}
