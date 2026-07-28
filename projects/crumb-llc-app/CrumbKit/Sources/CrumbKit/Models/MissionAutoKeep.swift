import Foundation

/// What Crumb would keep on its own, given a plan, what the kit already holds, and the deck.
///
/// The rule is deliberately narrow, and the narrowness is the whole safety story: **one keep per plan
/// part the kit does not cover yet, taken in the deck's own ranked order.** A card whose part is
/// already covered is *passed over*, not skipped — it stays on `remainingDeckIDs` for the person to
/// meet — so delegation can only ever put things in the kit, never quietly rule them out.
///
/// The obvious alternative, "walk the deck and stop at the first card that adds nothing", is what an
/// earlier draft of this specified, and it does not work: the settled deck is one globally fit-ranked
/// union with no per-part interleaving, so the top of a five-part kit's deck is usually several cards
/// of the *same* part in a row. Stopping at the first non-advancing card therefore ends the pass on
/// card two of a healthy run — collapsing five questions into four rather than into one.
///
/// Money: this never spends any. A kept pick is a shortlist entry; the cart and every checkout stay a
/// human tap. The one price rule here is a refusal — a candidate ``PriceBand`` flags as a mispriced
/// high outlier (the $1,450 tea in a $4–$60 deck) is never kept automatically. It is handed back with
/// its reason, and because it is never added, the part it would have covered stays open for the next
/// candidate. Below `PriceBand`'s minimum sample there is no band and no refusal: with three priced
/// items there is no norm to be an outlier against, and nothing irreversible happens either way.
///
/// Pure and model-free — same inputs, same answer, on device or in CI.
public enum MissionAutoKeep {

    /// One product auto chose to act on, and the checklist part that made it the one.
    public struct Pick: Sendable, Equatable {
        public let product: Product
        public let part: String?

        public init(product: Product, part: String?) {
            self.product = product
            self.part = part
        }
    }

    public struct Selection: Sendable, Equatable {
        /// Kept, in the order taken.
        public let kept: [Pick]
        /// Refused and left on the deck, with ``heldBackReason`` naming why.
        public let heldBack: [Pick]
        public let heldBackReason: String?

        public init(kept: [Pick], heldBack: [Pick] = [], heldBackReason: String? = nil) {
            self.kept = kept
            self.heldBack = heldBack
            self.heldBackReason = heldBackReason
        }

        public var isEmpty: Bool { kept.isEmpty }
    }

    /// Delegation is a kit-scale idea: below this many checklist parts there is nothing to divide up,
    /// and the single-item shortlist mission is precisely the one whose whole point is that the person
    /// looks at each candidate.
    public static let minimumParts = 2

    /// Says what `PriceBand` actually computes — a robust median-based threshold — rather than
    /// claiming the item is the single most expensive thing in the pool, which the band never
    /// establishes and which is false whenever more than one candidate clears the cut.
    static let heldBackReason = "priced far above the typical price I found"

    /// The picks auto would take right now. Returns an empty selection whenever it should stay out of
    /// the way: too few checklist parts, an exhausted deck, or a kit that already covers everything.
    public static func selection(
        plan: [String],
        kit: [Product],
        deck: [Product],
        band: PriceBand?
    ) -> Selection {
        let parts = plan.filter { !RuleBasedRelevanceGate.orderedTokens($0).isEmpty }
        guard parts.count >= minimumParts, !deck.isEmpty else { return Selection(kept: []) }

        var held: [Product] = kit
        // `readsRationale: false` — a decision Crumb makes for itself must stand on what the
        // product *is*, never on the sentence Crumb wrote about it. See `KitCompleteness.assess`.
        var missing = Set(KitCompleteness.assess(plan: parts, items: held, readsRationale: false).missing)
        guard !missing.isEmpty else { return Selection(kept: []) }

        var kept: [Pick] = []
        var heldBack: [Pick] = []
        for product in deck {
            guard !missing.isEmpty else { break }
            let after = Set(KitCompleteness.assess(
                plan: parts, items: held + [product], readsRationale: false
            ).missing)
            // In plan order, so a bundle covering several parts is attributed to the first of them
            // rather than to whichever happened to hash first.
            guard let covered = parts.first(where: { missing.contains($0) && !after.contains($0) })
            else { continue }

            if band?.isHighOutlier(product) == true {
                // Refused, and deliberately not added: the part stays open, so the next candidate for
                // it still gets its turn instead of the run ending on a card nobody chose.
                heldBack.append(Pick(product: product, part: covered))
                continue
            }
            held.append(product)
            missing = after
            kept.append(Pick(product: product, part: covered))
        }

        // A refusal is only worth reporting alongside something that actually happened; with nothing
        // kept, the person is about to be asked about that very card in the ordinary way.
        guard !kept.isEmpty else { return Selection(kept: []) }
        return Selection(
            kept: kept,
            heldBack: heldBack,
            heldBackReason: heldBack.isEmpty ? nil : heldBackReason
        )
    }
}
