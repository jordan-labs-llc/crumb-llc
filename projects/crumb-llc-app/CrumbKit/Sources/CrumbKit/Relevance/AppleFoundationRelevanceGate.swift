import Foundation
import FoundationModels
import os

/// The "real" relevance gate: the deterministic ``RuleBasedRelevanceGate`` floor first — always —
/// then a best-effort on-device model pass that drops the subtler off-topic items word-overlap
/// can't catch (a glove that never says "lacrosse" but is plainly for a different sport). It
/// mirrors ``AppleFoundationCurator``: the model refines, but the deterministic floor is the
/// guarantee, and any model failure degrades silently back to it.
///
/// ## Why it's safe to always inject
/// - The floor runs unconditionally and already enforces "never empty the deck".
/// - The model pass only runs when there's a **comfortable surplus** over the floor — a small
///   deck (the mock/seed path, or a lean live result) skips the model entirely, so there's no
///   added latency or model variance where there's nothing safe to drop.
/// - The model only ever *removes*, and ``applyDrops(_:to:floor:)`` refuses any drop that would
///   strand the deck below the floor. A thrown call (offline / system not ready) keeps the floor.
public struct AppleFoundationRelevanceGate: RelevanceGate {

    private let rule = RuleBasedRelevanceGate()
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "RelevanceGate")

    public init() {}

    /// Headroom over the floor before a model pass is worth its latency — below this, the floor
    /// is already lean enough that there's nothing safe to trim.
    static let surplus = 4
    /// Cap on how many candidates we send the model (a context/latency guard, mirroring the
    /// curator's `rankDeckCap`). Items past the cap are never proposed for dropping, so they're
    /// kept — a safe bias.
    static let gateCap = 30

    public func filter(_ products: [Product], for mission: ShoppingTask, floor: Int) async -> [Product] {
        // The deterministic floor first — always. This is the tested guarantee and the degrade
        // target, and it already keeps at least `floor` candidates.
        let floored = await rule.filter(products, for: mission, floor: floor)

        // Only spend a model call when there's a comfortable surplus worth trimming.
        guard floored.count > floor + Self.surplus else { return floored }

        let device = SystemLanguageModel.default
        guard case .available = device.availability else { return floored }

        do {
            let offTopic = try await modelOffTopicIDs(in: floored, mission: mission, model: device)
            return Self.applyDrops(offTopic, to: floored, floor: floor)
        } catch {
            Self.log.error("Relevance model pass threw, keeping the deterministic floor: \(error.localizedDescription, privacy: .public)")
            return floored
        }
    }

    // MARK: Model pass

    /// One guided call returns the IDs the model judges clearly off-topic. Bounded response so it
    /// can't overflow the on-device context (the same lesson as the planner).
    private func modelOffTopicIDs(
        in products: [Product],
        mission: ShoppingTask,
        model: SystemLanguageModel
    ) async throws -> [String] {
        let head = Array(products.prefix(Self.gateCap))
        let session = LanguageModelSession(model: model, instructions: Self.instructions(mission: mission))
        let response = try await session.respond(
            to: Self.prompt(for: head),
            generating: OffTopicSelection.self,
            options: GenerationOptions(maximumResponseTokens: 512)
        )
        return response.content.offTopicIDs
    }

    /// Removes `ids` from `products`, but **never below the floor**: if the drop would strand the
    /// deck under `floor`, it's refused and the full set is kept (the deterministic floor wins).
    /// Pure — unit-tested.
    public static func applyDrops(_ ids: [String], to products: [Product], floor: Int) -> [Product] {
        guard !ids.isEmpty else { return products }
        let drop = Set(ids)
        let kept = products.filter { !drop.contains($0.id) }
        return kept.count >= max(0, floor) ? kept : products
    }

    // MARK: Prompt construction

    static func instructions(mission: ShoppingTask) -> String {
        """
        You are Crumb, a personal shopping curator. The current mission is:
        "\(mission.title)" — \(mission.subtitle)
        It is about: \(mission.plan.joined(separator: ", ")).

        You are given candidate products. Identify ONLY the ones that are clearly off-topic for \
        this mission — a different sport, category, or use entirely (for example, a rowing shirt \
        among lacrosse gear, or a kitchen item among camping gear). When in doubt, keep it: do not \
        list a product unless it plainly does not belong. Return only the IDs of the clearly \
        off-topic products, using only the IDs provided; if every candidate is plausibly on-topic, \
        return an empty list.
        """
    }

    static func prompt(for products: [Product]) -> String {
        var lines = ["Candidate products:"]
        for product in products {
            var line = "- [\(product.id)] \(product.name) — \(product.shop.name)"
            let description = product.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty { line += " — \(description.prefix(120))" }
            lines.append(line)
        }
        lines.append("Return the IDs of only the clearly off-topic products (empty if none).")
        return lines.joined(separator: "\n")
    }
}

/// The structured output of a relevance pass: the IDs to drop. Guided generation keeps the model
/// returning a clean ID list rather than prose; ``AppleFoundationRelevanceGate/applyDrops(_:to:floor:)``
/// then applies them under the never-empty floor.
@Generable
struct OffTopicSelection {
    @Guide(description: "The IDs of ONLY the clearly off-topic products, each from the provided list. Empty if all are plausibly on-topic.")
    var offTopicIDs: [String]
}
