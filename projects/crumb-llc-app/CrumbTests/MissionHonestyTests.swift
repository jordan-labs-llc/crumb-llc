import Testing
import Foundation
import CrumbKit
@testable import Crumb

/// The five things the mission screen was asserting that were not true, each pinned so a later
/// tidy-up can't quietly restore them. Every case here came out of a live UXR run on iOS 27 rather
/// than from reading the code, which is why the comments name what was on screen.
@Suite("Mission honesty")
@MainActor
struct MissionHonestyTests {

    private func model(planner: any MissionPlanner = RuleBasedMissionPlanner()) -> AppModel {
        AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            planner: planner
        )
    }

    // MARK: - The meter

    /// A real mission with a real kit, built through the reducer so the thread is one the app could
    /// actually be holding.
    private func keptHikeThread() async -> MissionThread {
        let model = self.model()
        model.enterPlan(with: SeedData.hike)          // six checklist parts
        await model.loadCandidates(for: SeedData.hike)
        for product in model.deck.prefix(2) { model.accept(product) }
        return model.activeThread!
    }

    @Test("A one-part mission draws no progress meter, however much is kept")
    func meterHiddenForSinglePartMission() async {
        var thread = await keptHikeThread()
        #expect(thread.kit.isEmpty == false)

        // Collapse it to the shape every real goal has today: `DirectMissionPlanner` emits exactly
        // one part whose query is the goal. This is the exact state the UXR captured — five kept,
        // $698.02, a solid full-width bar, and an open question underneath it.
        thread.plan = [MissionPlanPart(label: "Set up a home coffee bar", query: "home coffee bar")]
        #expect(MissionKitHeader(thread: thread).showsMeter == false)
    }

    @Test("A shortlist mission draws no meter even with several parts planned")
    func meterHiddenForSingleItemMission() async {
        var thread = await keptHikeThread()
        // `partCount` collapses to 1 on a shortlist mission whatever the plan length, so the
        // fraction is just as meaningless there — one product and its alternates, not six parts.
        thread.task = ShoppingTask(
            id: "shortlist", title: "A cast iron skillet", subtitle: "",
            plan: SeedData.hike.plan, curatorNote: "", accentHex: 0x1F5F4E,
            candidateIDs: [], searchQueries: ["cast iron skillet"], isSingleItem: true
        )
        #expect(thread.plan.count > 1)
        #expect(MissionKitHeader(thread: thread).showsMeter == false)
    }

    @Test("A genuinely multi-part mission still draws its meter")
    func meterShownForMultiPartMission() async {
        let thread = await keptHikeThread()
        #expect(thread.plan.count > 1)
        #expect(MissionKitHeader(thread: thread).showsMeter)
    }

    // MARK: - The planning line

    @Test("‘Planning this mission…’ stops rendering once planning is no longer what's running")
    func planningTurnRetiresWhenPlanningEnds() async {
        let model = self.model()
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        var thread = try! #require(model.activeThread)

        // Settled: the gather has replaced the planning receipt, so the line is history.
        #expect(MissionPlanningTurn.isLive(in: thread) == false)

        // While planning genuinely runs, it still reads — it is the only thing on screen saying so.
        thread.pendingOperation = MissionPendingOperation(
            retry: MissionRetryDescriptor(kind: .planning, input: "x", returnPhase: .planning),
            startedAt: Date()
        )
        #expect(MissionPlanningTurn.isLive(in: thread))

        // A gather in flight is not planning — the header's own counter owns that moment.
        thread.pendingOperation = MissionPendingOperation(
            retry: MissionRetryDescriptor(kind: .gathering, returnPhase: .deckReady),
            startedAt: Date()
        )
        #expect(MissionPlanningTurn.isLive(in: thread) == false)
    }

    // MARK: - The planning deadline

    /// A planner that never returns until the test lets it, so the deadline is exercised without
    /// sleeping for real time.
    private struct HangingPlanner: MissionPlanner {
        func plan(goal: String, profile: TasteProfile) async -> PlannedMission {
            // Long enough that the deadline always wins; cancelled by `planBounded` on timeout.
            try? await Task.sleep(for: .seconds(30))
            return PlannedMission(task: nil, tier: .onDevice, decline: "never reached")
        }
    }

    @Test("A planner that hangs is abandoned at the deadline and the mission still gets a plan")
    func planningDeadlineDegradesRatherThanHanging() async {
        let model = self.model(planner: HangingPlanner())
        model.planSettleDeadline = 0.2

        await model.runPlan(goal: "premium jasmine tea")

        // The mission is shoppable rather than stuck on "Starting your mission…" forever. Before the
        // bound, one benchmarked planning call took 158 seconds with nothing on screen but a spinner.
        let thread = try! #require(model.activeThread)
        #expect(thread.task != nil)
        #expect(thread.phase != .planning)
        // And it degrades *honestly* — the tier carries the reason, which is what drives the
        // "Couldn't reach the planner just now" note.
        #expect(model.plannerTier == .ruleBased(.offlineOrError))
    }

    @Test("A planner that answers inside the deadline is used unchanged")
    func planningInsideDeadlineIsNotDegraded() async {
        let model = self.model()                 // deterministic planner: returns immediately
        model.planSettleDeadline = 5

        await model.runPlan(goal: "premium jasmine tea")

        let thread = try! #require(model.activeThread)
        #expect(thread.task != nil)
        #expect(model.plannerTier != .ruleBased(.offlineOrError))
    }

    // MARK: - Not stealing focus

    @Test("A gather that lands while you're on Home leaves you on Home")
    func firstPickDoesNotYankYouOutOfHome() async {
        let model = self.model()
        model.enterPlan(with: SeedData.hike)
        // The person walks out to Home while the search runs — Home renders it live, with its own
        // state, found-count and Stop, so there is nothing to be dragged back for.
        model.route = .missions

        await model.loadCandidates(for: SeedData.hike)

        // The measured regression: on Home at t+10s, forced into the thread at t+12s by
        // `loadCandidates` setting `route = .missionThread` on the first pick.
        #expect(model.route == .missions)
        #expect(model.activeThread?.candidates.isEmpty == false)   // the work still happened
    }

    @Test("A gather that lands while you're in the mission leaves you there")
    func firstPickKeepsYouInTheMission() async {
        let model = self.model()
        model.enterPlan(with: SeedData.hike)
        model.route = .missionThread

        await model.loadCandidates(for: SeedData.hike)

        #expect(model.route == .missionThread)
    }

    // MARK: - Re-entry must not cancel live work

    /// A planner the test can hold open and then release, so "an operation is genuinely in flight"
    /// is a fact rather than a race.
    private final class GatedPlanner: MissionPlanner, @unchecked Sendable {
        private let entered = AsyncStream<Void>.makeStream()
        private let release = AsyncStream<Void>.makeStream()

        var didEnter: AsyncStream<Void> { entered.stream }
        func releaseNow() { release.continuation.yield(()) }

        func plan(goal: String, profile: TasteProfile) async -> PlannedMission {
            entered.continuation.yield(())
            for await _ in release.stream { break }
            return RuleBasedMissionPlanner.plan(goal: goal, reason: nil)
        }
    }

    @Test("Re-entering a mission that is still working does not interrupt it")
    func reEnteringLiveMissionDoesNotCancelIt() async {
        let planner = GatedPlanner()
        let model = self.model(planner: planner)
        model.planSettleDeadline = 30            // the gate decides, not the deadline

        let planning = Task { await model.runPlan(goal: "everything for a home bar cart") }
        for await _ in planner.didEnter { break }   // the planner is now inside the call

        let thread = try! #require(model.activeThread)
        #expect(model.hasLiveOperation)

        // Walk out, then walk back in — the exact gesture that produced "That work was interrupted.
        // You can try it again." with a Retry chip on a search that was still running.
        model.route = .missions
        model.resumeThread(thread)

        #expect(model.route == .missionThread)
        #expect(model.hasLiveOperation, "re-entry cancelled the operation it walked back into")
        #expect(
            model.activeThread?.timeline.contains { $0.kind == .interrupted } == false,
            "re-entry narrated a live operation as interrupted"
        )

        planner.releaseNow()
        await planning.value
    }

    @Test("A receipt with no worker behind it is still recovered")
    func strandedOperationStillRecovers() async {
        let model = self.model()
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)

        // The gather has finished, so nothing is running — but the thread carries a pending
        // operation, which is exactly what survives an app kill mid-search. The re-entry shortcut
        // must read this as dead, or a crashed mission would never be recoverable again.
        var stranded = try! #require(model.activeThread)
        stranded.pendingOperation = MissionPendingOperation(
            retry: MissionRetryDescriptor(kind: .gathering, returnPhase: .deckReady),
            startedAt: Date()
        )
        #expect(model.hasLiveOperation == false)

        model.resumeThread(stranded)

        #expect(
            model.activeThread?.timeline.contains { $0.kind == .interrupted } == true,
            "a stranded operation was not recovered"
        )
        #expect(model.route == .missionThread)
    }
}
