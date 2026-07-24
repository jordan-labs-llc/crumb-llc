import Foundation

/// The two judgments a direct mission still wants from a model before shopping: **is this goal
/// shoppable at all** (the decline gate) and **is it one product or a kit** (the shortlist-vs-kit
/// framing + relevance-gate breadth). Direct missions removed the upfront plan decomposition —
/// the agentic orchestrator decides the catalog calls — but these two calls are exactly where the
/// word-cue heuristics mis-fire ("dorm room refresh" reads as one product; "sourdough starter
/// kit" reads as a kit), so they stay a model judgment: one cheap guided call, floored by the
/// deterministic heuristics when no model is up.
public struct GoalJudgment: Sendable, Equatable {
    /// Whether the goal is something a shop can fulfill (false → a friendly decline).
    public let isShoppable: Bool
    /// Whether the goal names ONE specific product (shortlist framing, narrow relevance gate)
    /// rather than a set of complementary things (kit framing, broad gate).
    public let isSingleItem: Bool
    /// Which tier judged it — reuses ``PlannerTier`` so the UI tells the same honest story as
    /// every other seam (`.ruleBased(reason)` means a model was wanted but unavailable).
    public let tier: PlannerTier

    public init(isShoppable: Bool, isSingleItem: Bool, tier: PlannerTier) {
        self.isShoppable = isShoppable
        self.isSingleItem = isSingleItem
        self.tier = tier
    }
}

/// The goal-triage seam behind ``DirectMissionPlanner``: judge a free-text goal without
/// decomposing it. Never throws — an unusable model degrades to the deterministic heuristics.
public protocol GoalTriage: Sendable {
    func judge(_ goal: String) async -> GoalJudgment
}

/// The deterministic triage floor: the same pure heuristics the rule-based planner uses
/// (``RuleBasedMissionPlanner/isShoppable(_:)`` + ``RuleBasedMissionPlanner/isSingleItem(goal:)``).
/// The default for the mock scaffold and the sim/CI, and the degrade target for
/// ``AppleFoundationGoalTriage``.
public struct RuleBasedGoalTriage: GoalTriage {

    public init() {}

    public func judge(_ goal: String) async -> GoalJudgment {
        // `reason: nil` — the chosen default (mock scaffold / sim), so the UI stays quiet. The
        // model triage passes a real reason when it degrades here.
        Self.judge(goal, reason: nil)
    }

    /// The deterministic judgment with an explicit fallback `reason`, so the model triage can
    /// reuse this floor and still report *why* it degraded. Pure — unit-tested.
    static func judge(_ goal: String, reason: PlannerTier.Fallback?) -> GoalJudgment {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return GoalJudgment(
            isShoppable: RuleBasedMissionPlanner.isShoppable(trimmed),
            isSingleItem: RuleBasedMissionPlanner.isSingleItem(goal: trimmed),
            tier: .ruleBased(reason)
        )
    }
}
