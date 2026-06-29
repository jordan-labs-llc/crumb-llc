import Foundation

/// The relevance seam: drops catalog items that are clearly **off-topic** for a mission *before*
/// the curator ranks and voices them, so a stray live result — a rowing shirt surfaced for a
/// lacrosse kit — never reaches the deck with a confident, model-written rationale. The curator
/// only ever *ranks*; it never *drops*. This is the missing drop step.
///
/// It mirrors the other Crumb seams exactly: a deterministic ``RuleBasedRelevanceGate`` floor
/// (the keyword match the sim/CI exercise and that's exhaustively unit-tested) and an optional
/// on-device ``AppleFoundationRelevanceGate`` that adds a best-effort model pass on top of —
/// and degrading to — that floor.
///
/// ## The one hard contract: never empty a real result set
/// An over-eager gate must never turn "we found things" into "no matches". Every implementation
/// keeps at least `floor` candidates: when too few items match, the relevant ones are topped up
/// from the best of the remainder rather than thinned toward nothing. With a deck at or below the
/// floor (the mock/seed path), the gate is a pass-through — so seed decks, all relevant to their
/// seed mission, are never disturbed.
public protocol RelevanceGate: Sendable {
    /// Returns `products` with clearly off-topic items removed, always keeping at least
    /// `min(floor, products.count)` candidates so a real deck is never emptied.
    func filter(_ products: [Product], for mission: ShoppingTask, floor: Int) async -> [Product]
}
