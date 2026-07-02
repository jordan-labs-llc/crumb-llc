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
        Self.keep(
            products,
            matching: Self.keywords(for: mission),
            core: Self.coreTerms(for: mission),
            floor: floor,
            excludePets: !Self.missionMentionsPets(mission)
        )
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

    /// Core-term–aware keep: for a **narrow** mission (`core` non-empty) a candidate must share one
    /// of the mission's distinctive core terms — the head qualifier "jasmine", not the generic
    /// category word "tea". When enough do (`onCore >= floor`) the off-core items are dropped
    /// outright: this is what finally removes the black/green tea that drifted into a jasmine deck,
    /// which the plain any-keyword ``keep(_:matching:floor:)`` kept because it shared "premium"/"tea".
    ///
    /// When too few match to trust the strict drop, the on-core items lead and the remainder tops up
    /// to the floor in input order, so a thin catalog is never stranded below it (the price band is
    /// the backstop for any off-core outlier that rides in as filler). `core` empty — a broad or
    /// multi-part mission — is exactly the plain any-keyword ``keep(_:matching:floor:)``, unchanged,
    /// so a genuinely varied deck (a lacrosse kit spanning stick/gloves/pads) is never over-trimmed.
    ///
    /// Pure and model-free: same inputs always produce the same kept set.
    ///
    /// `excludePets` is the negative floor for a mission about human equipment: when set, any product
    /// whose title, description, or merchant domain clearly reads as a *pet* product is dropped up
    /// front and never tops the deck back up as filler — so a "Lacrosse Dog Collar" (which shares
    /// "lacrosse") or a lacrosse stick sold by `3poochescollars.com` can't ride keyword overlap into a
    /// player-gear kit (#64). It is only ever set when the mission itself doesn't mention pets (see
    /// ``missionMentionsPets(_:)``), so a genuine "new collar for the dog" mission is untouched.
    public static func keep(_ products: [Product], matching keywords: Set<String>, core: Set<String>, floor: Int, excludePets: Bool = false) -> [Product] {
        let products = excludePets ? products.filter { !looksLikePetProduct($0) } : products
        guard !core.isEmpty else { return keep(products, matching: keywords, floor: floor) }
        let floor = max(0, floor)
        let onCore = products.filter { isRelevant($0, keywords: core) }
        guard onCore.count < floor else { return onCore }
        // Too few on-core to trust the strict drop — keep them first, then top up from the remainder
        // in input order so we never strand the user below the floor.
        let onCoreIDs = Set(onCore.map(\.id))
        let filler = products.filter { !onCoreIDs.contains($0.id) }
        return onCore + filler.prefix(floor - onCore.count)
    }

    /// The distinctive "core" terms a **narrow** mission is about — the head qualifier(s) a candidate
    /// must share to survive the strict gate (e.g. `{"jasmine"}` for "premium jasmine tea"). Empty
    /// for broad/multi-part missions, where any-keyword overlap is the right altitude and a strict
    /// gate would wrongly drop a legitimately varied deck.
    ///
    /// A mission is narrow when it has a single search part — the "single-item altitude" the planner
    /// already collapses to. From that one query we take the significant words in order, drop generic
    /// quality adjectives ("premium", "best") and the trailing head noun ("tea" — the category
    /// itself, which is exactly what lets an adjacent category match), and keep the remaining
    /// qualifiers. Pure.
    public static func coreTerms(for mission: ShoppingTask) -> Set<String> {
        let parts = mission.searchQueries.isEmpty ? mission.plan : mission.searchQueries
        guard parts.count == 1, let query = parts.first else { return [] }
        return distinctiveTerms(in: query)
    }

    /// The distinctive qualifier(s) of a single query: its significant words in order, minus generic
    /// quality adjectives and the trailing head noun. Returns the lone remaining word when nothing
    /// else is left (a bare-category goal like "premium tea" → `{"tea"}`, so it still requires the
    /// category), and empty for an all-generic/all-stopword query. Pure.
    static func distinctiveTerms(in query: String) -> Set<String> {
        let ordered = orderedTokens(query).filter { !genericQualifiers.contains($0) }
        guard ordered.count > 1 else { return Set(ordered) }
        // The trailing token is the head noun (the category, e.g. "tea"); the qualifiers before it
        // ("jasmine") are the distinctive signal a candidate must share.
        return Set(ordered.dropLast())
    }

    // MARK: - Pet / novelty negative floor (#64)

    /// Whether the mission is itself about pets — the guard that keeps the pet negative filter from
    /// touching a genuine "a new collar for the dog" mission. True when any of the mission's concrete
    /// shopping signal (queries, plan, title, subtitle) names an animal or pet-supply concept. Pure.
    ///
    /// Deliberately *broad* (it errs toward "yes, this is a pet mission" and so toward keeping pet
    /// products): a false positive here only means we don't apply the negative filter, which is the
    /// safe direction — far better than silently dropping the very products a pet mission is for.
    public static func missionMentionsPets(_ mission: ShoppingTask) -> Bool {
        let text = (mission.searchQueries + mission.plan + [mission.title, mission.subtitle])
            .joined(separator: " ")
        return !tokens(text).isDisjoint(with: petMissionWords)
    }

    /// Whether a product clearly reads as a *pet* product — matched on its title/description tokens or
    /// its merchant domain. Used only as a negative floor for non-pet missions (see
    /// ``missionMentionsPets(_:)``), so it can be conservative: it catches the obvious offenders (a
    /// "Lacrosse Dog Collar", a stick sold by `3poochescollars.com`) without reaching for ambiguous
    /// words like a shirt "collar" that also mean something to human gear. Pure.
    public static func looksLikePetProduct(_ product: Product) -> Bool {
        if !tokens(product.name + " " + product.rationale).isDisjoint(with: petProductWords) {
            return true
        }
        // The domain is the only tell for a pet-shop product with a human-sounding title
        // ("Hot Pink/Black Lacrosse Sticks" from 3poochescollars.com). Match distinctive pet
        // substrings, not tokens — a domain like "3poochescollars" doesn't split into "pooch".
        let domain = (product.shop.id + " " + product.shop.name).lowercased()
        return petDomainMarkers.contains { domain.contains($0) }
    }

    /// Pet/animal words that mark a **mission** as pet-oriented. Broader than ``petProductWords`` —
    /// it includes ambiguous supply words ("collar", "leash", "crate") because here they only widen
    /// the safe "leave pet products alone" case. Pure data.
    static let petMissionWords: Set<String> = [
        "dog", "dogs", "doggy", "doggie", "puppy", "puppies", "pooch", "pooches", "canine",
        "cat", "cats", "kitten", "kittens", "kitty", "feline", "pet", "pets",
        "leash", "leashes", "collar", "collars", "harness", "crate", "kennel", "aquarium",
        "hamster", "rabbit", "bunny", "parrot", "terrarium", "paw", "paws",
    ]

    /// Pet words distinctive enough to mark a **product** as pet-only from its title/description, even
    /// for a non-pet mission — kept tight (no bare "cat", which collides with the CAT footwear brand;
    /// no "collar", which is also a shirt part) so it never drops real human gear. Pure data.
    static let petProductWords: Set<String> = [
        "dog", "dogs", "doggy", "doggie", "puppy", "puppies", "pooch", "pooches", "canine",
        "kitten", "kittens", "kitty", "feline", "pet", "pets", "leash", "leashes",
    ]

    /// Distinctive substrings that mark a merchant **domain** as a pet shop — matched as substrings
    /// (not tokens) so a run-together domain like `3poochescollars` still resolves, and chosen to be
    /// specific enough not to fire on sports brands ("bulldoglacrosse" is caught by neither because
    /// there is no bare "dog" marker here). Pure data.
    static let petDomainMarkers: [String] = [
        "pooch", "puppy", "poodle", "kitten", "petco", "petsmart", "petstore", "petsuppl",
        "petboutique", "dogcollar", "dogleash", "pawprint",
    ]

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
        Set(orderedTokens(text))
    }

    /// The same significant tokens as ``tokens(_:)`` but in source order (and keeping repeats), so
    /// callers that care about position — which word is the trailing head noun — can. Pure.
    static func orderedTokens(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3, !stopwords.contains(word) else { continue }
            out.append(word)
        }
        return out
    }

    /// Generic quality/marketing adjectives that carry no *category* signal — they describe how nice
    /// a thing is, not what it is. Stripped from a narrow query before we pick the distinctive core
    /// term, so "premium jasmine tea" cores on "jasmine", not "premium". Kept small and only applied
    /// to the query (never to product names), so it can't strip a real product keyword.
    static let genericQualifiers: Set<String> = [
        "premium", "luxury", "deluxe", "quality", "fine", "finest", "best", "top",
        "classic", "signature", "gourmet", "professional", "standard", "value",
        "budget", "affordable",
    ]

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
