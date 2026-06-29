import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the planning seam. The model call itself stays
/// untested (unavailable on CI/sim, exactly like the curator/extractor) — but the pure
/// reconcile (`mission(from:goal:tier:)`), the rule-based floor, and the recents merge are
/// exercised exhaustively here.
@Suite("MissionPlanner")
struct MissionPlannerTests {

    // MARK: Rule-based floor (the always-on sim/CI planner)

    @Test("A shoppable goal becomes a one-part mission whose query is the cleaned goal")
    func ruleBasedShoppable() async {
        let planned = await RuleBasedMissionPlanner().plan(
            goal: "  set up my pour-over corner  ", profile: SeedData.defaultTasteProfile
        )
        let task = try? #require(planned.task)
        #expect(planned.isShoppable)
        #expect(task?.searchQueries == ["set up my pour-over corner"]) // single generic query
        #expect(task?.plan.count == 1)
        #expect(task?.title == "Set up my pour-over corner")           // title-cased
        #expect(planned.tier == .ruleBased(nil))                       // chosen default → quiet UI
        #expect(planned.tier.fallbackNote == nil)
    }

    @Test("An empty or too-short goal is not shoppable and carries a decline message")
    func ruleBasedEmptyDeclines() async {
        for goal in ["", "   ", "x"] {
            let planned = await RuleBasedMissionPlanner().plan(goal: goal, profile: SeedData.defaultTasteProfile)
            #expect(planned.task == nil, "goal: \(goal)")
            #expect(planned.decline == RuleBasedMissionPlanner.declineMessage)
            #expect(!planned.isShoppable)
        }
    }

    @Test("A bare question is treated as asking, not shopping")
    func ruleBasedQuestionDeclines() {
        #expect(!RuleBasedMissionPlanner.isShoppable("what's the weather?"))
        #expect(!RuleBasedMissionPlanner.isShoppable("how do I tie a tie?"))
        // A shopping request that merely contains a question mark elsewhere still shops.
        #expect(RuleBasedMissionPlanner.isShoppable("gift for mom, what's nice?"))
        #expect(RuleBasedMissionPlanner.isShoppable("set up my pour-over corner"))
    }

    @Test("A degraded AI planner reports its reason so the UI shows an honest note")
    func ruleBasedFallbackReason() {
        let planned = RuleBasedMissionPlanner.plan(goal: "warm winter layers", reason: .offlineOrError)
        #expect(planned.isShoppable)
        #expect(planned.tier == .ruleBased(.offlineOrError))
        #expect(planned.tier.fallbackNote != nil)
    }

    @Test("The mission id is stable and slugified from the goal")
    func missionIDStable() {
        let a = RuleBasedMissionPlanner.missionID(for: "Set up my Pour-Over corner!!")
        let b = RuleBasedMissionPlanner.missionID(for: "  set up my pour-over corner  ")
        #expect(a == b)                              // case/punct/space-insensitive
        #expect(a == "goal.set-up-my-pour-over-corner")
        #expect(RuleBasedMissionPlanner.missionID(for: "!!!") == "goal.mission") // no slug → safe default
    }

    @Test("The accent is deterministic across calls for the same goal")
    func accentDeterministic() {
        #expect(
            RuleBasedMissionPlanner.accentHex(for: "rainy hike")
                == RuleBasedMissionPlanner.accentHex(for: "Rainy Hike")
        )
    }

    // MARK: Reconcile (the pure fold of a model draft → mission)

    @Test("A full valid draft folds into a clean, searchable mission")
    func reconcileFull() {
        let draft = MissionDraft(
            isShoppable: true,
            title: "Set up my pour-over corner",
            subtitle: "Slower mornings",
            note: "Here's where I'd start.",
            parts: [
                PlanPartDraft(label: "Gooseneck kettle", query: "gooseneck kettle"),
                PlanPartDraft(label: "Burr grinder", query: "burr coffee grinder"),
            ],
            decline: ""
        )
        let planned = AppleFoundationMissionPlanner.mission(from: draft, goal: "pour over setup", tier: .onDevice)
        let task = planned.task

        #expect(task?.title == "Set up my pour-over corner")
        #expect(task?.subtitle == "Slower mornings")
        #expect(task?.curatorNote == "Here's where I'd start.")
        #expect(task?.plan == ["Gooseneck kettle", "Burr grinder"])
        #expect(task?.searchQueries == ["gooseneck kettle", "burr coffee grinder"])
        #expect(planned.tier == .onDevice)            // proven tier preserved
    }

    @Test("Blank title/subtitle/note in the draft backfill from deterministic defaults")
    func reconcileBackfillsBlankFields() {
        let draft = MissionDraft(
            isShoppable: true, title: "  ", subtitle: "", note: "  ",
            parts: [PlanPartDraft(label: "Rain shell", query: "rain jacket")],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "rainy hike kit", tier: .onDevice).task
        #expect(task?.title == "Rainy hike kit")                      // from goal
        #expect(task?.subtitle == RuleBasedMissionPlanner.defaultSubtitle)
        #expect(task?.curatorNote.isEmpty == false)                  // synthesized note
    }

    @Test("Garbage parts are dropped, half-filled parts repaired, duplicates collapsed, count capped")
    func reconcileCleansParts() {
        var parts = [
            PlanPartDraft(label: "  ", query: "  "),                  // empty → dropped
            PlanPartDraft(label: "Kettle", query: ""),               // query borrows label
            PlanPartDraft(label: "", query: "burr grinder"),         // label borrows query
            PlanPartDraft(label: "Kettle again", query: "Kettle"),   // dup query (case-insensitive) → dropped
        ]
        // Push well past the cap with unique queries to prove the cap.
        for i in 0..<10 { parts.append(PlanPartDraft(label: "Item \(i)", query: "query \(i)")) }

        let cleaned = AppleFoundationMissionPlanner.cleanParts(parts)
        #expect(cleaned.count == RuleBasedMissionPlanner.maxParts)   // capped at 6
        #expect(cleaned[0] == (label: "Kettle", query: "Kettle"))    // empty query borrows the label (case preserved)
        #expect(cleaned[1] == (label: "burr grinder", query: "burr grinder")) // empty label borrows the query
        // No duplicate queries survive.
        let queries = cleaned.map { $0.query.lowercased() }
        #expect(Set(queries).count == queries.count)
    }

    @Test("A shoppable draft with no usable parts degrades to the single-query plan")
    func reconcileEmptyPartsFallsBackToSingleQuery() {
        let draft = MissionDraft(
            isShoppable: true, title: "", subtitle: "", note: "",
            parts: [PlanPartDraft(label: "", query: "")],            // nothing usable
            decline: ""
        )
        let planned = AppleFoundationMissionPlanner.mission(from: draft, goal: "cozy reading nook", tier: .onDevice)
        let task = planned.task
        #expect(task?.searchQueries == ["cozy reading nook"])        // same as the rule-based floor
        #expect(task?.plan.count == 1)
        #expect(planned.tier == .onDevice)                           // tier still reported as proven
    }

    @Test("A not-shoppable draft yields no task and a decline message")
    func reconcileNotShoppable() {
        let withMsg = MissionDraft(
            isShoppable: false, title: "", subtitle: "", note: "", parts: [],
            decline: "I shop for things — try a goal."
        )
        let a = AppleFoundationMissionPlanner.mission(from: withMsg, goal: "what's the weather", tier: .onDevice)
        #expect(a.task == nil)
        #expect(a.decline == "I shop for things — try a goal.")

        // A blank decline backfills the deterministic message.
        let blank = MissionDraft(isShoppable: false, title: "", subtitle: "", note: "", parts: [], decline: "  ")
        let b = AppleFoundationMissionPlanner.mission(from: blank, goal: "asdf", tier: .onDevice)
        #expect(b.task == nil)
        #expect(b.decline == RuleBasedMissionPlanner.declineMessage)
    }

    // MARK: Goal cap (the fixed-prompt-cost guard that keeps the model call under context)

    @Test("A short goal is passed to the model untouched (just trimmed)")
    func cappedGoalShort() {
        #expect(AppleFoundationMissionPlanner.cappedGoal("  set up my pour-over corner  ")
            == "set up my pour-over corner")
    }

    @Test("An over-long goal is cut at a word boundary within the cap")
    func cappedGoalLong() {
        let long = String(repeating: "lacrosse gear and more ", count: 60)   // ~1380 chars
        let capped = AppleFoundationMissionPlanner.cappedGoal(long)
        #expect(capped.count <= AppleFoundationMissionPlanner.maxGoalChars)
        #expect(!capped.hasSuffix(" "))            // trimmed
        #expect(!capped.hasSuffix("lacros"))       // never split mid-word
    }
}

/// Recents-merge guarantees: dedupe, most-recent-first, cap.
@Suite("RecentMissionsStore")
@MainActor
struct RecentMissionsStoreTests {

    @Test("Adding goals keeps them most-recent-first")
    func mostRecentFirst() {
        let store = InMemoryRecentMissionsStore()
        store.addRecent("hike kit")
        store.addRecent("pour over corner")
        #expect(store.loadRecents() == ["pour over corner", "hike kit"])
    }

    @Test("Re-adding an existing goal moves it to the front (case-insensitive), no duplicate")
    func dedupeMovesToFront() {
        let store = InMemoryRecentMissionsStore(["a", "b", "c"])
        store.addRecent("B")
        #expect(store.loadRecents() == ["B", "a", "c"])
    }

    @Test("The list is capped at the store cap")
    func capped() {
        let store = InMemoryRecentMissionsStore()
        for i in 0..<10 { store.addRecent("goal \(i)") }
        #expect(store.loadRecents().count == InMemoryRecentMissionsStore.cap)
        #expect(store.loadRecents().first == "goal 9")              // newest kept
    }

    @Test("A blank goal is ignored")
    func blankIgnored() {
        let store = InMemoryRecentMissionsStore(["keep"])
        store.addRecent("   ")
        #expect(store.loadRecents() == ["keep"])
    }

    @Test("SwiftData store round-trips recents with dedupe + cap")
    func swiftDataRoundTrips() throws {
        let store = try SwiftDataRecentMissionsStore(inMemory: true)
        store.addRecent("hike kit")
        store.addRecent("pour over")
        store.addRecent("HIKE KIT")                                  // dup → front, no double
        #expect(store.loadRecents() == ["HIKE KIT", "pour over"])
    }
}
