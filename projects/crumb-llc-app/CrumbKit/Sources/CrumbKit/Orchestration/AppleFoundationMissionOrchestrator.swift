import Foundation
import FoundationModels
import os

/// The agentic gather tier: when a model is up, the model **drives** the search phase through Tools
/// — searching the catalog for each part of the mission, reaching past the given plan when the
/// mission needs it, and asking for more like a strong fit — with the relevance guard enforced on
/// every tool result before it enters the pool. It is the dynamic-session API's tool-calling loop
/// standing in for the fixed `search → gate` pipeline.
///
/// The deterministic pipeline is never abandoned: this tier degrades to
/// ``DeterministicMissionOrchestrator`` whenever no model is available *or* the agentic loop throws,
/// and it unions with the deterministic gather whenever the model gathered fewer than the floor — so
/// the agentic deck is never thinner than the floor pipeline would have produced. Model calls stay
/// untested in CI (the sim/CI hit the deterministic floor); the pure cores in ``GatherToolSupport``
/// and ``CandidateCollector`` carry the tested guarantees.
public struct AppleFoundationMissionOrchestrator: MissionOrchestrator {

    /// The mandatory floor: the degrade target and the source of the safety union.
    private let deterministic = DeterministicMissionOrchestrator()
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "MissionOrchestrator")

    public init() {}

    /// The gather loop wants steady, on-task tool use rather than creative latitude — run cool.
    static let temperature = 0.4
    /// The model's own text between tool calls is short (it's driving tools, not writing prose);
    /// bounded on the Profile so the multi-turn transcript can't overflow the 4096-token window.
    static let maxResponseTokens = 512

    public func gather(
        for mission: ShoppingTask,
        floor: Int,
        using ucp: any UCPClient,
        gate: any RelevanceGate,
        into collector: CandidateCollector
    ) async -> GatheredCandidates? {
        let device = SystemLanguageModel.default
        guard case .available = device.availability else {
            // No model — the mandatory deterministic floor, streaming through the same collector.
            return await deterministic.gather(for: mission, floor: floor, using: ucp, gate: gate, into: collector)
        }

        do {
            // The tools write into the *injected* collector, so its `picks` stream feeds the UI while
            // the model is still driving the loop.
            let tools: [any Tool] = [
                CatalogSearchTool(ucp: ucp, mission: mission, collector: collector),
                FindSimilarTool(ucp: ucp, mission: mission, collector: collector),
            ]
            let session = Self.makeSession(mission: mission, tools: tools, model: device)
            // The model drives: it calls the tools during this turn; the collector holds the pool,
            // so the returned text is ignored.
            _ = try await session.respond(to: Self.gatherPrompt(for: mission))
        } catch {
            Self.log.error("Agentic gather threw, using deterministic floor: \(error.localizedDescription, privacy: .public)")
            return await deterministic.gather(for: mission, floor: floor, using: ucp, gate: gate, into: collector)
        }

        var pool = await collector.products

        // Safety floor: if the model gathered fewer than the floor, union with the deterministic
        // gather (streaming its extra picks through the same collector) so the agentic deck is never
        // thinner than the floor pipeline would have produced.
        if pool.count < floor, let floorGather = await deterministic.gather(for: mission, floor: floor, using: ucp, gate: gate, into: collector) {
            pool = Self.mergeDedup(pool, floorGather.products)
        }

        // If the model gathered nothing usable at all, fall through to the floor entirely.
        guard !pool.isEmpty else {
            return await deterministic.gather(for: mission, floor: floor, using: ucp, gate: gate, into: collector)
        }
        return GatheredCandidates(products: pool, usedAgent: true)
    }

    // MARK: Session

    /// Builds the driver session and seeds its `@SessionProperty` mission brief. The session runs on
    /// ``OrchestratorProfile`` — a `DynamicProfile` that reads the brief from session state each turn
    /// and composes ``OrchestratorInstructions`` (which embed the Tools in their body — the
    /// composable way tools are registered) with the gather tuning + context policy.
    static func makeSession(
        mission: ShoppingTask,
        tools: [any Tool],
        model: SystemLanguageModel
    ) -> LanguageModelSession {
        let session = LanguageModelSession(profile: OrchestratorProfile(tools: tools, model: model))
        // Thread the mission context through session state (a @SessionProperty) rather than a
        // constructor arg, so the DynamicProfile can re-read it each turn as the loop evolves.
        session.properties.orchestrationBrief = OrchestratorInstructions.missionBrief(for: mission)
        return session
    }

    /// A tiny logging hook the driver profile fires on each tool call (the lifecycle hook — genuine
    /// observability into the agentic loop without altering behavior).
    static func logToolCall() { log.debug("orchestrator tool call") }

    /// Merges two pools, keeping `primary` order first then any new-by-id from `secondary`. Pure.
    static func mergeDedup(_ primary: [Product], _ secondary: [Product]) -> [Product] {
        var seen = Set(primary.map(\.id))
        var out = primary
        for product in secondary where seen.insert(product.id).inserted {
            out.append(product)
        }
        return out
    }

    /// The kickoff instruction — what to gather. The persona + tool guidance live in the
    /// instructions; this is the single turn that sets the loop going.
    static func gatherPrompt(for mission: ShoppingTask) -> String {
        let parts = mission.plan.isEmpty ? mission.searchQueries : mission.plan
        let partList = parts.isEmpty ? mission.title : parts.joined(separator: ", ")
        return """
        Assemble a strong set of candidate products for this mission: \(partList). \
        Search the catalog for each part, add searches for anything else the mission clearly needs, \
        and use find_similar to widen a strong fit. When you have a good, varied on-topic set, stop.
        """
    }
}

// MARK: - Tools

/// Searches the shop catalog for one part of the mission. The relevance guard runs on the results
/// before they enter the pool, so off-topic items never reach the curator.
struct CatalogSearchTool: Tool {
    let name = "search_catalog"
    let description = "Search the shop catalog for products for one part of the mission. Pass a few plain keyword terms (for example 'gooseneck kettle'). Call it once per part you want to shop for — including parts beyond the given plan if the mission clearly needs them."

    @Generable
    struct Arguments {
        @Guide(description: "A few plain keyword terms to search, e.g. 'wool base layer'. No punctuation.")
        var query: String
    }

    let ucp: any UCPClient
    let mission: ShoppingTask
    let collector: CandidateCollector

    func call(arguments: Arguments) async throws -> String {
        let query = GatherToolSupport.cleanedQuery(arguments.query)
        guard !query.isEmpty else { return "Empty query — provide a few keyword terms." }
        let raw = (try? await ucp.searchCatalog(query, placements: [.organic])) ?? []
        let kept = GatherToolSupport.onTopic(raw, for: mission)
        await collector.add(kept)
        let total = await collector.count
        return GatherToolSupport.summary(kept: kept, dropped: raw.count - kept.count) + " Pool now holds \(total)."
    }
}

/// Widens a strong fit: the model describes the kind of product it wants more of, and this searches
/// for it. Semantically "find more like this"; mechanically another guarded catalog search.
struct FindSimilarTool: Tool {
    let name = "find_similar"
    let description = "Find more products like a strong fit you already found. Describe the kind of item you want more of in a few plain words (for example 'minimalist ceramic pour-over dripper')."

    @Generable
    struct Arguments {
        @Guide(description: "A few plain words describing the kind of product to find more of. No punctuation.")
        var descriptor: String
    }

    let ucp: any UCPClient
    let mission: ShoppingTask
    let collector: CandidateCollector

    func call(arguments: Arguments) async throws -> String {
        let query = GatherToolSupport.cleanedQuery(arguments.descriptor)
        guard !query.isEmpty else { return "Empty descriptor — describe the kind of product." }
        let raw = (try? await ucp.searchCatalog(query, placements: [.organic])) ?? []
        let kept = GatherToolSupport.onTopic(raw, for: mission)
        await collector.add(kept)
        let total = await collector.count
        return GatherToolSupport.summary(kept: kept, dropped: raw.count - kept.count) + " Pool now holds \(total)."
    }
}

// MARK: - Session property + dynamic profile

public extension SessionPropertyValues {
    /// The running orchestration brief the driver reads each turn — which mission it is gathering
    /// for. Held as a `@SessionProperty` so ``OrchestratorProfile`` (a `DynamicProfile`) can re-read
    /// it as session state, the seam for a brief that evolves across a persistent per-mission driver.
    @SessionPropertyEntry var orchestrationBrief: String = ""
}

/// The driver's `DynamicProfile`: it reads the mission brief from session state (`@SessionProperty`)
/// each turn and composes ``OrchestratorInstructions`` (Tools embedded in the body) with the gather
/// tuning + pair-safe context policy. `historyTransform` is finally load-bearing here — unlike the
/// single-shot seams, the tool loop accumulates transcript turns, and ``CrumbContext/trimmed(_:)``
/// keeps them under the 4096-token window by cutting at whole tool-turn boundaries.
struct OrchestratorProfile: LanguageModelSession.DynamicProfile {
    @LanguageModelSession.SessionProperty(\.orchestrationBrief) var brief
    let tools: [any Tool]
    let model: SystemLanguageModel

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            OrchestratorInstructions(brief: brief, tools: tools)
        }
        .model(model)
        .temperature(AppleFoundationMissionOrchestrator.temperature)
        .maximumResponseTokens(AppleFoundationMissionOrchestrator.maxResponseTokens)
        // Pair-safe trim: cuts at whole tool-turn boundaries so a toolCalls/toolOutput pair is never
        // split (a naive most-recent-N trim corrupts the transcript — see CrumbContext).
        .historyTransform { CrumbContext.trimmed($0) }
        .transcriptErrorHandlingPolicy(.revertTranscript)
        .onToolCall { _ in AppleFoundationMissionOrchestrator.logToolCall() }
    }
}

// MARK: - Instructions

/// The orchestrator driver's instructions: the shared Crumb persona + the mission brief (threaded in
/// from session state) + how to use the Tools to gather. The Tools are embedded in the body — the
/// composable way the dynamic-session API registers them with the session.
struct OrchestratorInstructions: DynamicInstructions {
    let brief: String
    let tools: [any Tool]

    var body: some DynamicInstructions {
        CrumbPersona(recipient: nil)
        Instructions(brief)
        Instructions(Self.guide)
        tools
    }

    /// The mission framing the driver gathers for. Pure — unit-tested.
    static func missionBrief(for mission: ShoppingTask) -> String {
        let parts = mission.plan.isEmpty ? mission.searchQueries : mission.plan
        let partLine = parts.isEmpty ? "" : "\nThe mission's parts to shop for: \(parts.joined(separator: ", "))."
        return "You are assembling a set of candidate products for a shopping mission: "
            + "\"\(mission.title)\" — \(mission.subtitle).\(partLine)"
    }

    /// How to drive the gathering loop with the tools. Pure — unit-tested.
    static let guide = """
        Use the tools to gather a strong, varied set of on-topic candidates:
        - Call search_catalog once for each part of the mission, with a few plain keywords.
        - If the mission clearly needs something not in the listed parts, search for it too.
        - When a result is a strong fit, call find_similar to surface more like it.
        - Never search for things off-topic for this mission.
        Keep going until you have a good spread across the mission's parts, then stop. You do not need \
        to write a summary — the products you find are collected automatically.
        """
}
