import Foundation

/// The conversational-refinement seam: turns a free-text "talk back to the curator" line
/// ("make it cheaper", "warmer tones", "add rain pants") — plus the running per-mission
/// refinement conversation — into a structured ``RefinementDirective`` the app can act on.
///
/// This is the third on-device twin of ``CuratorEngine`` / ``MissionPlanner`` / ``TasteExtractor``:
/// the deterministic ``RuleBasedRefinementInterpreter`` is the offline floor, and
/// ``AppleFoundationRefinementInterpreter`` is the on-device interpreter that actually *reads*
/// the refinement. Both report the ``RefinementTier`` they ran on, so the UI can be honest when
/// it wanted the AI interpreter but had to fall back to the deterministic one.
///
/// A directive is **unified power**: it carries an `emphasis` note that re-ranks and re-voices
/// the *existing* deck, an optional `priceDirection` and `removeHints` that shape it
/// deterministically, AND optional `addQueries` for things the user asked for that aren't in the
/// deck yet. The app re-searches + merges only when `addQueries` is non-empty; otherwise it
/// re-curates the existing deck in place. This avoids a brittle "re-rank vs. search" either/or
/// classification — the interpreter just fills `addQueries` when the ask needs new candidates.
public protocol RefinementInterpreter: Sendable {
    /// Reads `refinement` (the latest line) in the context of the running `conversation` (all
    /// prior refinement lines this mission, oldest-first), the `mission`, and the user's
    /// `profile`, into a directive. Never throws: an unusable model tier degrades to the
    /// deterministic interpreter, which still maps chips and a keyword heuristic.
    func interpret(
        _ refinement: String,
        conversation: [String],
        mission: ShoppingTask,
        profile: TasteProfile
    ) async -> InterpretedRefinement
}

/// The result of an interpretation pass: the structured ``RefinementDirective`` plus the
/// ``RefinementTier`` that produced it, so the UI can surface an honest fallback note exactly
/// like planning and curation.
public struct InterpretedRefinement: Sendable, Equatable {
    public let directive: RefinementDirective
    public let tier: RefinementTier

    public init(directive: RefinementDirective, tier: RefinementTier) {
        self.directive = directive
        self.tier = tier
    }
}

/// What the user asked Crumb to change about the dealt deck, in structured form.
///
/// One directive carries every flavor of refinement so the app never has to classify the ask:
/// - `emphasis` — a free-text note that re-ranks and re-voices the existing candidates.
/// - `priceDirection` — a deterministic price lean the rule-based floor can honor with no model.
/// - `removeHints` — keywords for candidates to **demote** (push to the tail), e.g. "no synthetic".
/// - `addQueries` — catalog queries for things not in the deck yet (e.g. "add rain pants"); the
///   app re-searches + merges only when this is non-empty.
public struct RefinementDirective: Sendable, Equatable {
    /// A short re-ranking / re-voicing note ("warmer tones and materials"). May be empty.
    public var emphasis: String
    /// Catalog queries for items the user asked for that aren't in the deck. Capped at
    /// ``maxAddQueries``; empty means "re-curate the existing deck in place, don't search".
    public var addQueries: [String]
    /// A deterministic price lean for the deck.
    public var priceDirection: PriceDirection
    /// Keywords for existing candidates to demote (push toward the back), never hard-dropped so
    /// the deck can't be emptied by a refinement.
    public var removeHints: [String]

    public init(
        emphasis: String = "",
        addQueries: [String] = [],
        priceDirection: PriceDirection = .none,
        removeHints: [String] = []
    ) {
        self.emphasis = emphasis
        self.addQueries = addQueries
        self.priceDirection = priceDirection
        self.removeHints = removeHints
    }

    /// Which way the user wants price to lean. `.none` leaves the deck's price order alone.
    public enum PriceDirection: String, Sendable, Equatable, CaseIterable {
        case cheaper
        case pricier
        case none
    }

    /// How many `addQueries` a single refinement may pull in. A guard rail so "add a few things"
    /// can't flood the deck with searches; extras are dropped in ``cleanDirective(_:)``.
    public static let maxAddQueries = 3

    /// `true` when the directive asks for *something* — an emphasis, a price lean, a removal, or
    /// a new search. A directive with none of these is a no-op the app reports as "couldn't apply"
    /// rather than silently reworking nothing.
    public var isActionable: Bool {
        !emphasis.isEmpty || !addQueries.isEmpty || priceDirection != .none || !removeHints.isEmpty
    }
}

/// Which interpreter produced a directive. Mirrors ``CuratorTier`` / ``PlannerTier`` so the
/// refinement path tells the same honest story: `ruleBased(nil)` is the *chosen* offline default
/// (the UI stays quiet), while `ruleBased(reason)` means the AI interpreter was wanted but
/// unavailable, which the UI surfaces explicitly.
public enum RefinementTier: Sendable, Equatable {
    /// Apple's server-tier model (`PrivateCloudComputeLanguageModel`, OS 27+).
    case privateCloud
    /// The on-device model (`SystemLanguageModel.default`) — offline, lower quality.
    case onDevice
    /// The deterministic ``RuleBasedRefinementInterpreter``. `reason == nil` means it was the
    /// chosen default (the mock scaffold / sim) and the UI should stay quiet; a non-`nil` reason
    /// means an AI tier was *wanted* but unavailable.
    case ruleBased(Fallback?)

    /// Why an AI interpreter tier could not be used, so the UI can phrase an honest note.
    public enum Fallback: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case quotaExhausted
        case offlineOrError
    }
}

public extension RefinementTier {
    /// A short, user-facing note when an AI interpreter was wanted but unavailable, else `nil`.
    /// Kept in CrumbKit so the voice copy lives next to the seam, not in the views.
    var fallbackNote: String? {
        guard case let .ruleBased(reason?) = self else { return nil }
        switch reason {
        case .deviceNotEligible:
            return "Smart refining needs an Apple Intelligence device — I made the change as "
                + "best I could read it."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to let me read refinements in detail. "
                + "For now, I changed what I could."
        case .modelNotReady:
            return "My refining model is still downloading — I changed what I could read for now."
        case .quotaExhausted:
            return "You've used up this period's private-cloud refining — I changed what I could "
                + "read for now."
        case .offlineOrError:
            return "Couldn't reach the refiner just now — I changed what I could read from your "
                + "words."
        }
    }
}

/// The value threaded into ``CuratorEngine/curate(_:for:mission:refinement:)`` so ranking AND
/// voicing honor the refinement: the active ``RefinementDirective`` plus the running
/// `conversation` (all refinement lines this mission, oldest-first) so stacked refinements
/// ("cheaper" then "but keep the kettle") compose in the model's instructions.
public struct RefinementContext: Sendable, Equatable {
    public let directive: RefinementDirective
    public let conversation: [String]

    public init(directive: RefinementDirective, conversation: [String]) {
        self.directive = directive
        self.conversation = conversation
    }

    /// Deterministically reshapes a ranked deck to honor a directive's *structured* asks — the
    /// part that needs no model, so the rule-based floor (and a degraded AI tier's fallback) still
    /// visibly responds. A stable reorder, applied in order:
    ///
    /// 1. **Price** — a stable sort by price ascending (`.cheaper`) / descending (`.pricier`).
    /// 2. **Emphasis boost** — products whose name or rationale match an emphasis keyword are
    ///    stable-moved to the front (preserving their relative order).
    /// 3. **Remove demote** — products matching a `removeHints` keyword are stable-moved to the
    ///    tail. Never dropped, so a refinement can't empty the deck.
    ///
    /// Pure and model-free: same directive + deck always produces the same order. `nil` (or a
    /// non-actionable directive) returns the deck unchanged.
    public static func apply(_ context: RefinementContext?, to products: [Product]) -> [Product] {
        guard let directive = context?.directive, directive.isActionable else { return products }
        var out = products

        // 1. Price lean — stable sort keeps the curator's order within equal prices.
        switch directive.priceDirection {
        case .cheaper: out = stableSorted(out) { $0.price < $1.price }
        case .pricier: out = stableSorted(out) { $0.price > $1.price }
        case .none: break
        }

        // 2. Emphasis boost — float keyword matches to the front, order otherwise preserved.
        let emphasisKeywords = keywords(from: directive.emphasis)
        if !emphasisKeywords.isEmpty {
            out = stablePartition(out) { matches($0, anyOf: emphasisKeywords) }
        }

        // 3. Remove demote — sink keyword matches to the tail (kept, not dropped).
        let removeKeywords = directive.removeHints.flatMap { keywords(from: $0) }
        if !removeKeywords.isEmpty {
            out = stablePartition(out) { !matches($0, anyOf: removeKeywords) }
        }

        return out
    }

    // MARK: Pure shaping helpers

    /// A stable sort: ties keep their input order (Swift's `sorted(by:)` isn't guaranteed
    /// stable, which would let equal-priced products wobble between runs).
    static func stableSorted(_ products: [Product], by areInOrder: (Product, Product) -> Bool) -> [Product] {
        products.enumerated()
            .sorted { lhs, rhs in
                if areInOrder(lhs.element, rhs.element) { return true }
                if areInOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Stable partition: elements satisfying `predicate` first (in their original relative order),
    /// then the rest (likewise). Used for both the emphasis boost and the remove demote.
    static func stablePartition(_ products: [Product], _ predicate: (Product) -> Bool) -> [Product] {
        products.filter(predicate) + products.filter { !predicate($0) }
    }

    /// Splits a phrase into lowercased keywords ≥ 3 chars, dropping a few stop words so a note
    /// like "more durable, built to last" matches on "durable"/"built"/"last", not "more"/"to".
    static func keywords(from phrase: String) -> [String] {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// `true` when the product's name or rationale contains any of `keywords` as a substring.
    static func matches(_ product: Product, anyOf keywords: [String]) -> Bool {
        let haystack = (product.name + " " + product.rationale).lowercased()
        return keywords.contains { haystack.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "more", "less", "some", "any", "that", "this", "into",
        "make", "made", "them", "they", "its", "your", "you", "are", "but", "keep",
    ]
}
