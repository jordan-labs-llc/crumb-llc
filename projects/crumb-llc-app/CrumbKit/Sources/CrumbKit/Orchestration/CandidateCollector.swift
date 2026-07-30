import Foundation

/// Where a batch of gathered products came from: the part of the mission the search was run for.
///
/// The gather is a union of several searches, and until this existed the union was all that survived:
/// a kit mission's pool held the kettle, the grinder and the beans with no record of which search
/// found what. That is the whole reason kit missions could not offer alternatives — the products
/// beside the beans were other *parts*, not other beans.
///
/// `rank` is what makes the attribution order-independent. The mission's own queries fan out in
/// parallel, so when two of them return the same product the winner would otherwise depend on which
/// search happened to come back first. Lower rank wins: a planned search carries its position in the
/// plan, and a search the model invented for itself carries ``improvised``, so a plan part always
/// out-claims an improvised query and the same gather always attributes the same way.
public struct GatherOrigin: Hashable, Sendable {
    /// What the finds are attributed to — a plan part's label for a planned search ("Gooseneck
    /// kettle"), the model's own cleaned query for a search it reached for beyond the plan.
    public let part: String
    /// Lower wins when several searches return the same product.
    public let rank: Int

    /// The rank of a search the model invented rather than one the plan asked for.
    public static let improvised = Int.max

    public init(part: String, rank: Int) {
        self.part = part
        self.rank = rank
    }
}

/// Accumulates the products the agentic gather's Tools discover across the tool-calling loop —
/// deduped by id and capped — so repeated or overlapping searches can't double-count or grow the
/// pool unbounded. The relevance guard runs *before* anything is handed here — in each agentic
/// Tool, and per-batch in the deterministic gather — so the collector only ever holds on-topic,
/// first-seen products in discovery order (plus the deterministic floor's top-up, which is added
/// deliberately when too few matched). This matters beyond the stream: the gather safety net
/// settles on the collector snapshot, so an ungated add would reach the deck unfiltered.
///
/// An `actor` because the model may fan tool calls out concurrently; the dedupe/cap must be atomic.
public actor CandidateCollector {

    private var order: [Product] = []
    private var seen: Set<Product.ID> = []
    /// Which search claimed each pooled product. See ``GatherOrigin`` for why the claim is ranked
    /// rather than first-come.
    private var origins: [Product.ID: GatherOrigin] = [:]
    private let cap: Int
    private var continuation: AsyncStream<[Product]>.Continuation?
    /// Set by ``finish()``; makes ``add(_:)`` a full no-op afterward. With the #54 turn deadline a
    /// cancelled model turn can be a *zombie* whose tools still call ``add(_:)`` after settle — this
    /// keeps such late writes from mutating the pool nondeterministically (nobody reads it post-settle,
    /// so it was latent, but the deadline makes it reachable).
    private var finished = false

    /// A live stream of **newly-inserted** picks, one batch per ``add(_:)`` that discovered something
    /// first-seen. A progressive UI subscribes to this to show picks the moment they land — the
    /// "stream raw" half of stream-raw-then-settle — instead of waiting for the whole gather. It is
    /// `nonisolated` (immutable, `Sendable`) so a consumer can `for await` it without hopping the
    /// actor; the yields themselves are serialized by the actor against concurrent ``add(_:)``.
    public nonisolated let picks: AsyncStream<[Product]>

    /// `cap` bounds the pool the same way the curator's `rankDeckCap` bounds ranking — a big live
    /// catalog shouldn't let the loop gather hundreds of items the curator then can't hold.
    public init(cap: Int = 60) {
        self.cap = cap
        let (stream, continuation) = AsyncStream.makeStream(of: [Product].self)
        self.picks = stream
        self.continuation = continuation
    }

    /// Adds first-seen products in order until the cap is reached; ignores duplicates and overflow.
    /// Emits the batch of *newly-inserted* products (if any) on ``picks``.
    ///
    /// `origin` records which part of the mission this search was for. A duplicate is still worth
    /// hearing about for attribution: the pool already holds the product, but a better-ranked claim
    /// (a plan part over an improvised query, an earlier part over a later one) replaces a weaker
    /// one, which is what keeps the answer independent of the order the parallel searches return in.
    public func add(_ products: [Product], from origin: GatherOrigin? = nil) {
        // A full no-op once finished — a zombie turn's late tool writes must not touch the pool.
        guard !finished else { return }
        var inserted: [Product] = []
        for product in products {
            if !seen.contains(product.id) {
                // The pool is full: this one never joins it, so it earns no attribution either.
                // `continue` rather than `break` so a product already pooled further along the batch
                // can still have its claim improved.
                guard order.count < cap else { continue }
                seen.insert(product.id)
                order.append(product)
                inserted.append(product)
            }
            if let origin, origins[product.id].map({ origin.rank < $0.rank }) ?? true {
                origins[product.id] = origin
            }
        }
        if !inserted.isEmpty { continuation?.yield(inserted) }
    }

    /// Closes the ``picks`` stream — call once gathering is done so a subscriber's `for await` loop
    /// ends. Idempotent: a second call is a no-op.
    public func finish() {
        finished = true
        continuation?.finish()
        continuation = nil
    }

    /// The gathered pool, in discovery order.
    public var products: [Product] { order }

    /// Which part of the mission found each pooled product. Products gathered before any search
    /// named itself (an untagged ``add(_:from:)``) are simply absent — the caller treats an absent
    /// entry as "no idea", never as "belongs to no part".
    public var attribution: [Product.ID: String] { origins.mapValues(\.part) }

    /// How many products have been gathered so far (read by the tools to summarize progress).
    public var count: Int { order.count }
}

/// The pure, unit-tested helpers behind the agentic gather's Tools — the CI-safe core that runs the
/// same whether or not a model drives the loop.
public enum GatherToolSupport {

    /// Normalizes a model-supplied query the same way the planner cleans a plan query, so a stray
    /// bit of punctuation or casing can't split what is really one search. Pure.
    public static func cleanedQuery(_ raw: String) -> String {
        RuleBasedMissionPlanner.clean(query: raw)
    }

    /// The relevance guard applied to a single tool's results before they enter the collector:
    /// keep only the products sharing a significant word with what the mission is about, dropping
    /// the clearly off-topic. `floor: 0` means "keep exactly the on-topic set" (no top-up) — the
    /// overall floor is guaranteed later by the orchestrator's union with the deterministic gather.
    ///
    /// For a **narrow** (single-item) mission this also enforces the distinctive core term, so a
    /// whole drifted batch — the model searched "premium black tea" for a jasmine mission — is
    /// dropped at the tool boundary before it can pool.
    ///
    /// For a **kit-breadth** mission (`isSingleItem == false`) the searched `query`'s own words
    /// join the mission keywords: the orchestrator is *instructed* to reach beyond the listed
    /// parts ("dorm room refresh" → a desk lamp search), so results matching the search it just
    /// ran must not be dropped at the tool boundary for sharing no word with the goal text. A
    /// single-item mission deliberately ignores `query` — that's the drift protection.
    ///
    /// Reuses ``RuleBasedRelevanceGate`` so tool-time filtering and the gate agree. Pure.
    public static func onTopic(_ products: [Product], for mission: ShoppingTask, query: String = "") -> [Product] {
        var keywords = RuleBasedRelevanceGate.keywords(for: mission)
        if !mission.isSingleItem {
            keywords.formUnion(RuleBasedRelevanceGate.tokens(query))
        }
        return RuleBasedRelevanceGate.keep(
            products,
            matching: keywords,
            core: RuleBasedRelevanceGate.coreTerms(for: mission),
            floor: 0,
            excludePets: !RuleBasedRelevanceGate.missionMentionsPets(mission)
        )
    }

    /// Which part of the mission a search belongs to, so its finds can be attributed.
    ///
    /// The model is *instructed* to call `search_catalog` once per listed part, so a tool query that
    /// matches one of the mission's own queries is that part's search and is attributed to the part's
    /// label — the words the person read on the Plan screen. A query the model reached for beyond the
    /// plan ("the mission clearly needs a desk lamp") has no part to belong to, so it becomes its own,
    /// improvised part named by the query itself. Pure.
    public static func origin(for query: String, in mission: ShoppingTask) -> GatherOrigin {
        // Case-folded on both sides: nothing constrains how the model capitalizes its arguments, and
        // "Gooseneck Kettle" is the plan's own search however it was typed. The improvised label is
        // folded too, so one invented search doesn't become two parts over a capital letter.
        let cleaned = cleanedQuery(query).lowercased()
        guard let index = mission.searchQueries.firstIndex(where: { cleanedQuery($0).lowercased() == cleaned })
        else { return GatherOrigin(part: cleaned, rank: GatherOrigin.improvised) }
        return GatherOrigin(part: partLabel(at: index, in: mission), rank: index)
    }

    /// The label the `index`-th planned search's finds are attributed to. The plan and the queries are
    /// built as parallel arrays, so the part at the same position is the answer — but only while they
    /// line up: a part whose query cleans away to nothing is dropped from the queries alone, and
    /// pairing by position through that gap would file every later part's finds under its neighbour.
    /// The query is the honest fallback. Pure.
    static func partLabel(at index: Int, in mission: ShoppingTask) -> String {
        guard mission.plan.count == mission.searchQueries.count,
              mission.plan.indices.contains(index) else {
            return mission.searchQueries.indices.contains(index)
                ? mission.searchQueries[index]
                : mission.title
        }
        return mission.plan[index]
    }

    /// A compact, model-readable summary of what a tool call found — the tool's return value. Kept
    /// short so a long result list can't blow the context window. Pure.
    public static func summary(kept: [Product], dropped: Int) -> String {
        guard !kept.isEmpty else {
            return dropped > 0
                ? "No on-topic products (dropped \(dropped) off-topic). Try a different query."
                : "No products found. Try a different query."
        }
        // Keep the summary short (a few examples) — in the tool loop it lands in the transcript, so
        // a long list would eat the on-device context window.
        let names = kept.prefix(3).map(\.name).joined(separator: "; ")
        let more = kept.count > 3 ? " (+\(kept.count - 3) more)" : ""
        let droppedNote = dropped > 0 ? " Dropped \(dropped) off-topic." : ""
        return "Found \(kept.count) on-topic: \(names)\(more).\(droppedNote)"
    }
}
