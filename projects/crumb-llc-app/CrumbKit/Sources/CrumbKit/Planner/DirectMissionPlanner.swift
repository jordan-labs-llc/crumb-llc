import Foundation

/// The direct-mission planner — the default planning seam now that the upfront FM plan
/// decomposition and its approval turn are gone. It builds the deterministic mission shell
/// (title, query, framing, accents) in ~1ms and delegates the only judgments that still want a
/// model — `isShoppable` + `isSingleItem` — to the injected ``GoalTriage`` (one cheap guided
/// call, heuristic floor). The *intelligence* of the search itself lives downstream in the
/// agentic ``AppleFoundationMissionOrchestrator``, which decides the catalog calls.
///
/// Kit-cue goals are the one place a plan survives: a recognized sports-gear goal expands to the
/// deterministic player kit (``RuleBasedMissionPlanner/kitExpansion(for:)``) so safety/fit
/// completeness never depends on a model — surfaced in-thread as an editable notice, not an
/// approval turn.
public struct DirectMissionPlanner: MissionPlanner {

    private let triage: any GoalTriage

    public init(triage: any GoalTriage = RuleBasedGoalTriage()) {
        self.triage = triage
    }

    public func plan(goal: String, profile: TasteProfile) async -> PlannedMission {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RuleBasedMissionPlanner.plan(goal: trimmed, reason: nil) }
        let judgment = await triage.judge(trimmed)
        return Self.mission(goal: trimmed, judgment: judgment)
    }

    /// Folds a triage judgment into a searchable mission (or an honest decline). Pure and
    /// model-free — the unit-tested guarantee behind the seam:
    ///
    /// - **Not shoppable** → the deterministic decline.
    /// - **A recognized sports-kit goal** → the deterministic multi-part player kit, regardless
    ///   of the single-item judgment (safety/fit completeness must never hinge on the model).
    /// - **Otherwise** → the one-part shell whose single query is the cleaned goal, framed by
    ///   the judgment's `isSingleItem` (shortlist vs kit — which also sets the relevance gate's
    ///   breadth downstream).
    static func mission(goal: String, judgment: GoalJudgment) -> PlannedMission {
        guard judgment.isShoppable else {
            return PlannedMission(
                task: nil, tier: judgment.tier, decline: RuleBasedMissionPlanner.declineMessage
            )
        }
        // A recognized kit intent decomposes deterministically, regardless of the single-item
        // judgment — completeness must never hinge on the model. See ``KitRecipes`` for the
        // measurements that put coverage here rather than in a prompt: the model named 44% of the
        // parts a kit needs and agreed with itself 27% of the time, and neither a better prompt nor
        // sampling three times moved that past 61%.
        if let recipe = KitRecipes.recipe(for: goal) {
            let task = RuleBasedMissionPlanner.makeTask(
                goal: goal,
                title: RuleBasedMissionPlanner.title(from: goal),
                subtitle: RuleBasedMissionPlanner.defaultSubtitle,
                note: recipe.assumption,
                parts: recipe.parts,
                isSingleItem: false
            )
            return PlannedMission(task: task, tier: judgment.tier, decline: nil)
        }
        let title = RuleBasedMissionPlanner.title(from: goal)
        let task = RuleBasedMissionPlanner.makeTask(
            goal: goal,
            title: title,
            subtitle: RuleBasedMissionPlanner.defaultSubtitle,
            note: RuleBasedMissionPlanner.curatorNote(forParts: [title]),
            parts: [(label: title, query: RuleBasedMissionPlanner.clean(query: goal))],
            isSingleItem: judgment.isSingleItem
        )
        return PlannedMission(task: task, tier: judgment.tier, decline: nil)
    }
}
