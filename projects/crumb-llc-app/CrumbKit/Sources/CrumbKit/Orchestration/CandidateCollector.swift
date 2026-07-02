import Foundation

/// Accumulates the products the agentic gather's Tools discover across the tool-calling loop —
/// deduped by id and capped — so repeated or overlapping searches can't double-count or grow the
/// pool unbounded. The relevance guard runs in each Tool *before* handing results here, so the
/// collector only ever holds on-topic, first-seen products in discovery order.
///
/// An `actor` because the model may fan tool calls out concurrently; the dedupe/cap must be atomic.
public actor CandidateCollector {

    private var order: [Product] = []
    private var seen: Set<Product.ID> = []
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
    public func add(_ products: [Product]) {
        // A full no-op once finished — a zombie turn's late tool writes must not touch the pool.
        guard !finished else { return }
        var inserted: [Product] = []
        for product in products where !seen.contains(product.id) {
            guard order.count < cap else { break }
            seen.insert(product.id)
            order.append(product)
            inserted.append(product)
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
    /// For a **narrow** mission this also enforces the distinctive core term, so a whole drifted
    /// batch — the model searched "premium black tea" for a jasmine mission — is dropped at the
    /// tool boundary before it can pool. Reuses ``RuleBasedRelevanceGate`` so tool-time filtering
    /// and the gate agree. Pure.
    public static func onTopic(_ products: [Product], for mission: ShoppingTask) -> [Product] {
        RuleBasedRelevanceGate.keep(
            products,
            matching: RuleBasedRelevanceGate.keywords(for: mission),
            core: RuleBasedRelevanceGate.coreTerms(for: mission),
            floor: 0,
            excludePets: !RuleBasedRelevanceGate.missionMentionsPets(mission)
        )
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
