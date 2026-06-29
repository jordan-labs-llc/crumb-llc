import Foundation

/// The deterministic relevance floor — the default gate on the simulator/CI and the degrade
/// target for ``AppleFoundationRelevanceGate``. It keeps any product whose name or merchant
/// description shares a significant word with what the mission is *about* (its search queries,
/// plan labels, and title), and drops the rest — but never below the floor.
///
/// It does not try to be clever: word-overlap is enough to drop a rowing shirt from a lacrosse
/// kit while keeping every genuinely on-topic item. The richer judgement (a glove that never
/// says "lacrosse" but clearly belongs) is the job of the optional model pass; this is the
/// dependable floor it builds on, and the shared home of the pure, unit-tested helpers.
public struct RuleBasedRelevanceGate: RelevanceGate {

    public init() {}

    public func filter(_ products: [Product], for mission: ShoppingTask, floor: Int) async -> [Product] {
        Self.keep(products, matching: Self.keywords(for: mission), floor: floor)
    }

    // MARK: - Pure core (the unit-tested guarantee behind the gate)

    /// The significant words a mission is "about": its search queries and plan labels — the
    /// concrete things to shop for — tokenized into lowercased words with stopwords and 1–2
    /// character tokens dropped. Pure.
    ///
    /// The mission *title* is deliberately excluded: it's model-written framing that often carries
    /// proper nouns and generic filler (a recipient's name, "kit", "season") which would let an
    /// off-topic item match on a name collision — exactly the "Men's Zephyr … Kit Shop" rowing
    /// shirt that slipped into a lacrosse deck. The queries and plan labels are the deliberate,
    /// concrete shopping signal.
    public static func keywords(for mission: ShoppingTask) -> Set<String> {
        tokens((mission.searchQueries + mission.plan).joined(separator: " "))
    }

    /// Keeps every product sharing a keyword with the mission and drops the clearly off-topic —
    /// but never returns fewer than `min(floor, products.count)`:
    ///
    /// - **Enough match** (`relevant >= floor`) → return just the relevant set; the off-topic are
    ///   dropped.
    /// - **Too few match** → keep the relevant ones, then top up from the untouched remainder in
    ///   input order, so a thin or oddly-named deck is never stranded below the floor.
    /// - **No keywords** (a mission with no queries/plan) → pass everything through; there's
    ///   nothing to match on, and this is the mock/seed path where the deck is already curated.
    ///
    /// Pure and model-free: same inputs always produce the same kept set.
    public static func keep(_ products: [Product], matching keywords: Set<String>, floor: Int) -> [Product] {
        guard !keywords.isEmpty else { return products }
        let floor = max(0, floor)
        let relevant = products.filter { isRelevant($0, keywords: keywords) }
        guard relevant.count < floor else { return relevant }
        // Too few matched to trust the gate — keep the relevant ones first, then top up from the
        // remainder (input order) so we never strand the user below the floor.
        let relevantIDs = Set(relevant.map(\.id))
        let filler = products.filter { !relevantIDs.contains($0.id) }
        return relevant + filler.prefix(floor - relevant.count)
    }

    /// A product is on-topic when its name or merchant description shares at least one significant
    /// word with the mission's keywords. (At gate time — before the curator voices the deck —
    /// `rationale` is still the raw merchant description, which helps a sparsely-named product
    /// match.) Pure.
    public static func isRelevant(_ product: Product, keywords: Set<String>) -> Bool {
        !tokens(product.name + " " + product.rationale).isDisjoint(with: keywords)
    }

    /// Lowercased word tokens split on any non-alphanumeric, with stopwords and 1–2 character
    /// tokens dropped. Pure and deterministic.
    static func tokens(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3, !stopwords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }

    /// Common words that carry no topic signal — deliberately small and generic so it never
    /// strips a real product keyword (note "kit", "gear", "bag", etc. are *not* here).
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "your", "you", "our", "their", "his", "her", "its",
        "this", "that", "these", "those", "are", "was", "were", "from", "into", "out",
        "off", "set", "get", "got", "had", "has", "have", "but", "not", "all", "any",
        "can", "will", "would", "should", "could", "about", "than", "then", "them",
        "some", "more", "most", "much", "very", "just", "like", "what", "when", "where",
        "who", "why", "how", "need", "needs", "want", "wants", "make", "made", "let",
    ]
}
