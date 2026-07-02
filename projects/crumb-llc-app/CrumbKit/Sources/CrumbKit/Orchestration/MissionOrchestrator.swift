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

    public init(products: [Product], usedAgent: Bool) {
        self.products = products
        self.usedAgent = usedAgent
    }
}

public extension UCPClient {
    /// Fans `queries` out to the catalog **in parallel** and dedupes the union by product id.
    /// Returns `nil` only when *every* query errored (a real outage), so callers can distinguish an
    /// outage from a successful-but-empty result. The shared fan-out behind both the deterministic
    /// gather and `AppModel`'s refinement search, so they behave identically.
    func searchUnion(_ queries: [String]) async -> [Product]? {
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
        let succeeded = batches.compactMap { $0 }
        guard !succeeded.isEmpty else { return nil }
        var seen = Set<Product.ID>()
        return succeeded.flatMap { $0 }.filter { seen.insert($0.id).inserted }
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
        // Fan the queries out in parallel and add each query's raw batch to the collector *as it
        // returns*, so a subscriber sees picks stream in rather than waiting for the whole union.
        // The collector dedupes by id, so overlapping queries (the mock collapses them) never
        // double-count. `try?` keeps one failed query from cancelling its siblings; a query that
        // errors contributes nothing.
        let anySucceeded = await withTaskGroup(of: Bool.self) { group in
            for query in queries {
                group.addTask {
                    guard let batch = try? await ucp.searchCatalog(query, placements: [.organic]) else { return false }
                    await collector.add(batch)
                    return true
                }
            }
            var succeeded = false
            for await ok in group { succeeded = succeeded || ok }
            return succeeded
        }
        // A total outage (every query errored) is `nil`, so the caller can tell it from an empty
        // success — matching `searchUnion`'s contract.
        guard anySucceeded else { return nil }
        // Drop clearly off-topic items before the curator ranks/voices them; the gate keeps at least
        // `floor` candidates, so it can never turn a real result set into "no matches".
        let gated = await gate.filter(collector.products, for: mission, floor: floor)
        return GatheredCandidates(products: gated, usedAgent: false)
    }
}
