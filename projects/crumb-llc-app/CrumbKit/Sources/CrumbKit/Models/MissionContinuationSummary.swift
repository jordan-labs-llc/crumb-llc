import Foundation

/// The one-line state a person reads on a Continue row before deciding whether to reopen a mission.
///
/// Deriving this from `phase` alone is what produced the "Picks ready" label over a deck that had
/// found nothing: `deckReady` is a *state-machine* fact — the gather finished — not a claim about
/// contents. Every branch that could be contradicted by the thread's own data therefore reads that
/// data instead. Phases that carry no contents (planning, gathering, failure, closure) keep their
/// plain wording, because for those the phase IS the whole truth.
///
/// This is presentation copy, but it lives in the domain layer deliberately: it is an interpretation
/// of mission state, it is the kind of thing that goes quietly wrong, and here it is covered by the
/// fast unit suite instead of a multi-minute UI run.
public enum MissionContinuationSummary {
    /// Short status for a Continue row. Also used verbatim inside the row's accessibility label.
    public static func text(for thread: MissionThread, currencyCode: String = "USD") -> String {
        switch thread.phase {
        case .planning: return "Planning"
        case .planReady: return "Ready to shop"
        case .gathering: return "Searching shops"
        case .failed: return "Needs attention"
        case .declined: return "Ready for another goal"
        case .completed: return "Completed"
        case .abandoned: return "Ended"
        case .deckReady:
            // Kept items outrank unreviewed ones: if you already chose something, that — and what
            // it costs — is the reason to come back, and it doubles as the only route to the kit
            // (the cart is reachable only from inside a mission).
            if !thread.kit.isEmpty {
                let subtotal = thread.kit.reduce(Decimal.zero) { $0 + $1.variant.price }
                let count = thread.kit.count == 1 ? "1 kept" : "\(thread.kit.count) kept"
                return "\(count) · \(subtotal.formatted(.currency(code: currencyCode)))"
            }
            if !thread.remainingDeckIDs.isEmpty {
                let count = thread.remainingDeckIDs.count
                return count == 1 ? "1 pick to review" : "\(count) picks to review"
            }
            // The gather completed and produced nothing. Saying so is the whole point of this type.
            return "Nothing found yet"
        }
    }
}
