import Foundation

/// The seam that gathers a mission's candidate pool — the **search + relevance** phase of the
/// curate pipeline, before the curator ranks and voices.
///
/// Two tiers, mirroring every other Crumb seam:
/// - ``DeterministicMissionOrchestrator`` — the mandatory floor: fan the mission's queries out to
///   the catalog in parallel, dedupe, and drop the clearly off-topic. This is exactly the pipeline
///   `AppModel.loadCandidates` used to run inline, and it is what the simulator/CI and any no-model
///   device fall back to.
/// - ``AppleFoundationMissionOrchestrator`` — the agentic tier: when a model is up, the model
///   *drives* the gathering through Tools (search the catalog, find more like a strong fit,
///   reach past the given plan), with the relevance guard enforced on every tool result. It
///   degrades to the deterministic floor whenever no model is available or the loop fails.
///
/// The orchestrator only *gathers*; the caller still hands the pool to the curator for ranking and
/// voicing. `gather` returns `nil` ONLY on a total catalog outage (every search errored), so the
/// caller can tell an outage from a genuinely empty result.
public protocol MissionOrchestrator: Sendable {
    /// Gathers into `collector`, which streams each newly-discovered batch on ``CandidateCollector/picks``
    /// so a progressive UI can show raw picks as they land. Returns the terminal, relevance-settled
    /// pool (the same value the non-streaming ``gather(for:floor:using:gate:)`` returns) once
    /// gathering is complete, or `nil` on a total catalog outage.
    func gather(
        for mission: ShoppingTask,
        floor: Int,
        using ucp: any UCPClient,
        gate: any RelevanceGate,
        into collector: CandidateCollector
    ) async -> GatheredCandidates?
}

public extension MissionOrchestrator {
    /// Convenience for callers that don't observe the stream — gathers into a throwaway collector
    /// and returns only the terminal pool. This is the shape the tests and any non-progressive
    /// caller use; the streaming `into:` form is what ``AppModel`` drives for stream-raw-then-settle.
    func gather(
        for mission: ShoppingTask,
        floor: Int,
        using ucp: any UCPClient,
        gate: any RelevanceGate
    ) async -> GatheredCandidates? {
        await gather(for: mission, floor: floor, using: ucp, gate: gate, into: CandidateCollector())
    }
}

/// The result of a gather: the relevance-filtered candidate pool plus whether the agentic tier
/// actually drove it (so the UI/telemetry can tell "the model shopped for you" from the floor).
public struct GatheredCandidates: Sendable, Equatable {
    public let products: [Product]
    public let usedAgent: Bool
    /// Which part of the mission found each product — a plan part's label for a planned search, the
    /// model's own query for one it reached for beyond the plan. Empty for a gather that ran before
    /// anything named its searches; a product missing from the map was found by an unnamed search,
    /// which the caller reads as "no idea", never as "belongs to no part".
    ///
    /// This is what makes a kit mission's pool more than a union: without it the kettle, the grinder
    /// and the beans are indistinguishable neighbours, so nothing downstream can tell an alternative
    /// from a different part of the same errand.
    public let parts: [Product.ID: String]

    public init(products: [Product], usedAgent: Bool, parts: [Product.ID: String] = [:]) {
        self.products = products
        self.usedAgent = usedAgent
        self.parts = parts
    }
}

public extension UCPClient {
    /// Fans `queries` out to the catalog **in parallel** and dedupes the union by product id.
    /// Returns `nil` only when *every* query errored (a real outage), so callers can distinguish an
    /// outage from a successful-but-empty result. The shared fan-out behind both the deterministic
    /// gather and `AppModel`'s refinement search, so they behave identically.
    func searchUnion(_ queries: [String]) async -> [Product]? {
        await searchUnionByQuery(queries)?.products
    }

    /// ``searchUnion(_:)`` with the provenance kept: which query found each product, so a search
    /// outside the initial gather (a refinement's `addQueries`) can name its own finds instead of
    /// adding candidates nothing can place. The earliest query that returned a product owns it,
    /// which is the same rank rule ``GatherOrigin`` states — and for the same reason: the queries
    /// race, and the answer must not.
    func searchUnionByQuery(
        _ queries: [String]
    ) async -> (products: [Product], parts: [Product.ID: String])? {
        // `try?` keeps a failed query from cancelling its siblings; a failure surfaces as `nil`.
        // Batches are slotted back by query index (not task-completion order) so the union — and thus
        // the deck built from it — is deterministic regardless of which search returns first. Mirrors
        // the indexed task group in ``AppleFoundationCurator/mapRankChunks``.
        let batches: [[Product]?] = await withTaskGroup(of: (Int, [Product]?).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, try? await self.searchCatalog(query, placements: [.organic])) }
            }
            var collected = [[Product]?](repeating: nil, count: queries.count)
            for await (index, batch) in group { collected[index] = batch }
            return collected
        }
        guard batches.contains(where: { $0 != nil }) else { return nil }
        var seen = Set<Product.ID>()
        var products: [Product] = []
        var parts: [Product.ID: String] = [:]
        for (index, batch) in batches.enumerated() {
            guard let batch else { continue }
            for product in batch where seen.insert(product.id).inserted {
                products.append(product)
                parts[product.id] = queries[index]
            }
        }
        return (products, parts)
    }
}

/// The deterministic gather floor: the exact search → relevance-gate pipeline that
/// `AppModel.loadCandidates` ran inline, now a seam so the agentic tier can degrade to it and the
/// whole pipeline is unit-testable. Model-free — the simulator/CI default.
public struct DeterministicMissionOrchestrator: MissionOrchestrator {

    public init() {}

    public func gather(
        for mission: ShoppingTask,
        floor: Int,
        using ucp: any UCPClient,
        gate: any RelevanceGate,
        into collector: CandidateCollector
    ) async -> GatheredCandidates? {
        // A mission with no queries falls back to its id, exactly like the old inline pipeline.
        let queries = mission.searchQueries.isEmpty ? [mission.id] : mission.searchQueries
        // Fan the queries out in parallel, gating each batch (`floor: 0` — drop-only, mirroring the
        // agentic Tools) *before* it enters the collector, so a subscriber streams only on-topic
        // picks. The collector must never hold an ungated product: it is shared with the agentic
        // tier, whose safety net settles on the collector snapshot — a raw add here would reach the
        // deck unfiltered whenever the watchdog launches this floor. The raw batches are kept,
        // slotted by query index so the union is deterministic, for the floor top-up below.
        // `try?` keeps one failed query from cancelling its siblings; a query that errors
        // contributes nothing.
        let rawBatches: [[Product]?] = await withTaskGroup(of: (Int, [Product]?).self) { group in
            for (index, query) in queries.enumerated() {
                // Each query carries its plan position as the origin rank, so a product two parts
                // both return is attributed to the earlier part however the searches race.
                let origin = GatherOrigin(
                    part: GatherToolSupport.partLabel(at: index, in: mission), rank: index
                )
                group.addTask {
                    guard let batch = try? await ucp.searchCatalog(query, placements: [.organic]) else {
                        return (index, nil)
                    }
                    await collector.add(gate.filter(batch, for: mission, floor: 0), from: origin)
                    return (index, batch)
                }
            }
            var collected = [[Product]?](repeating: nil, count: queries.count)
            for await (index, batch) in group { collected[index] = batch }
            return collected
        }
        // A total outage (every query errored) is `nil`, so the caller can tell it from an empty
        // success — matching `searchUnion`'s contract.
        let succeeded = rawBatches.compactMap { $0 }
        guard !succeeded.isEmpty else { return nil }
        var seen = Set<Product.ID>()
        let rawUnion = succeeded.flatMap { $0 }.filter { seen.insert($0.id).inserted }
        // The floor guarantee: the on-topic set, topped back up to `floor` from the raw union when
        // too few matched — so an over-eager gate can never turn a real result set into "no matches".
        let gated = await gate.filter(rawUnion, for: mission, floor: floor)
        // A top-up item was (rightly) dropped by the batch gate above and so never streamed; add it
        // now, because the settle keeps only cards that streamed and would silently drop it. The
        // collector dedupes, so re-adding the on-topic items is a no-op. Added one query at a time,
        // in query order, so a top-up is attributed to the search that actually returned it rather
        // than arriving as one anonymous batch.
        for (index, batch) in rawBatches.enumerated() {
            guard let batch else { continue }
            let found = Set(batch.map(\.id))
            let mine = gated.filter { found.contains($0.id) }
            guard !mine.isEmpty else { continue }
            await collector.add(
                mine, from: GatherOrigin(part: GatherToolSupport.partLabel(at: index, in: mission), rank: index)
            )
        }
        // The collector caps the pool; return only what it actually holds so the terminal pool
        // never contains a product that couldn't stream.
        let pooled = Set(await collector.products.map(\.id))
        return GatheredCandidates(
            products: gated.filter { pooled.contains($0.id) },
            usedAgent: false,
            parts: await collector.attribution
        )
    }
}
