import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the direct-mission planning chain: the triage floor's
/// heuristics, and the pure fold from a ``GoalJudgment`` into a searchable mission (or decline).
/// The model triage itself stays untested (unavailable on CI/sim, like every model seam) — these
/// are the floors and reconciles it degrades to.
@Suite("DirectMissionPlanner")
struct DirectMissionPlannerTests {

    // MARK: Triage floor

    @Test("The rule-based triage mirrors the planner heuristics and reports its tier")
    func triageFloor() async {
        let judged = await RuleBasedGoalTriage().judge("premium jasmine tea")
        #expect(judged.isShoppable)
        #expect(judged.isSingleItem)
        #expect(judged.tier == .ruleBased(nil))

        let question = await RuleBasedGoalTriage().judge("what is the weather?")
        #expect(!question.isShoppable)
    }

    @Test("A degraded triage carries the fallback reason so the UI can be honest")
    func triageDegradeReason() {
        let judged = RuleBasedGoalTriage.judge("premium jasmine tea", reason: .offlineOrError)
        #expect(judged.tier == .ruleBased(.offlineOrError))
    }

    // MARK: The pure judgment → mission fold

    @Test("A shoppable single-item judgment yields the one-part shell with shortlist framing")
    func singleItemShell() {
        let planned = DirectMissionPlanner.mission(
            goal: "premium jasmine tea",
            judgment: GoalJudgment(isShoppable: true, isSingleItem: true, tier: .onDevice)
        )
        let task = planned.task
        #expect(task?.isSingleItem == true)
        #expect(task?.searchQueries == ["premium jasmine tea"])   // the goal verbatim, cleaned
        #expect(task?.plan.count == 1)
        #expect(planned.tier == .onDevice)                        // the triage's tier is reported
        #expect(planned.decline == nil)
    }

    @Test("A shoppable kit judgment yields a broad one-part shell (the gate stays wide)")
    func kitShellStaysBroad() {
        // "dorm room refresh" — the judgment the word-cue heuristics fumble; the model says kit.
        let planned = DirectMissionPlanner.mission(
            goal: "dorm room refresh",
            judgment: GoalJudgment(isShoppable: true, isSingleItem: false, tier: .onDevice)
        )
        let task = planned.task
        #expect(task?.isSingleItem == false)
        #expect(task?.plan.count == 1)
        // The downstream consequence the flag drives: no core term, so the agentic
        // orchestrator's beyond-plan searches survive the relevance gate.
        #expect(RuleBasedRelevanceGate.coreTerms(for: task!).isEmpty)
    }

    @Test("A single-item judgment keeps its narrow gate (core term) downstream")
    func singleItemStaysNarrow() {
        let planned = DirectMissionPlanner.mission(
            goal: "premium jasmine tea",
            judgment: GoalJudgment(isShoppable: true, isSingleItem: true, tier: .onDevice)
        )
        #expect(RuleBasedRelevanceGate.coreTerms(for: planned.task!) == ["jasmine"])
    }

    @Test("A not-shoppable judgment declines with the deterministic message")
    func declineFold() {
        let planned = DirectMissionPlanner.mission(
            goal: "what is the weather?",
            judgment: GoalJudgment(isShoppable: false, isSingleItem: false, tier: .onDevice)
        )
        #expect(planned.task == nil)
        #expect(planned.decline == RuleBasedMissionPlanner.declineMessage)
        #expect(planned.tier == .onDevice)
    }

    @Test("A recognized sports-kit goal expands to the deterministic player kit, even if the judgment said single-item")
    func sportsKitOverridesJudgment() {
        // The model mis-framing "lacrosse gear" as one product must never collapse the
        // safety/fit kit — the deterministic expansion wins.
        let planned = DirectMissionPlanner.mission(
            goal: "lacrosse gear for my son",
            judgment: GoalJudgment(isShoppable: true, isSingleItem: true, tier: .onDevice)
        )
        let task = planned.task
        #expect(task?.isSingleItem == false)
        #expect((task?.plan.count ?? 0) >= 4)
        #expect(task?.plan.contains("Helmet") == true)
        #expect(task?.curatorNote.localizedCaseInsensitiveContains("field player") == true)
    }

    @Test("The planner seam end-to-end on the triage floor: shell for a goal, decline for a question")
    func plannerSeamEndToEnd() async {
        let planner = DirectMissionPlanner()   // rule-based triage floor
        let shopped = await planner.plan(goal: "premium jasmine tea", profile: SeedData.defaultTasteProfile)
        #expect(shopped.task?.isSingleItem == true)
        #expect(shopped.task?.searchQueries == ["premium jasmine tea"])

        let declined = await planner.plan(goal: "what is the weather?", profile: SeedData.defaultTasteProfile)
        #expect(declined.task == nil)
        #expect(declined.decline != nil)
    }

    @Test("The heuristic floor still mis-frames the two known cases — the model call exists for a reason")
    func heuristicFloorKnownLimits() {
        // Documented, deliberate: these are the judgments the guided FM call corrects on-device.
        // If a heuristic change ever fixes these, the triage seam's guide text should be revisited.
        #expect(RuleBasedMissionPlanner.isSingleItem(goal: "dorm room refresh"))          // wrongly "one product"
        #expect(!RuleBasedMissionPlanner.isSingleItem(goal: "sourdough starter kit"))     // wrongly "a kit"
    }

    @Test("The triage instructions and judgment guide stay judgment-only")
    func triageGuideShape() {
        #expect(TriageInstructions.guide.contains("isShoppable"))
        #expect(TriageInstructions.guide.contains("isSingleItem"))
        #expect(TriageInstructions.guide.contains("sourdough starter kit"))
        #expect(TriageInstructions.guide.contains("dorm room"))
    }
}
