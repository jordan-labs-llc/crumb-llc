import Testing
import Foundation
import CrumbKit
@testable import Crumb

/// Delegation end to end through the real reducer: what Auto keeps, what it records, what it refuses
/// to touch, and how completely Undo puts it back.
///
/// The seed hike mission is the honest fixture for this — six checklist parts against six candidates,
/// five of which name a part's head noun and one ("Granite Trail Runners" against "Grippy trail
/// shoes") that does not. So a correct pass keeps five, passes over the sixth, and leaves a real
/// question on the table, which is exactly the shape the feature has to survive.
@Suite("Mission approvals")
@MainActor
struct MissionApprovalsTests {

    private func settledHikeMission() async -> AppModel {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        return model
    }

    private func receipt(in model: AppModel) -> MissionAutoKeepSnapshot? {
        for event in model.activeThread?.timeline.reversed() ?? [] {
            for block in event.blocks {
                if case .autoKeep(let snapshot) = block { return snapshot }
            }
        }
        return nil
    }

    // MARK: The pass

    @Test("Auto keeps one pick per uncovered part, and says so in a single receipt")
    func autoKeepsOnePerPart() async throws {
        let model = await settledHikeMission()
        #expect(model.kit.isEmpty)
        #expect(model.missionApprovalMode == .askEach)
        #expect(model.missionAllowsDelegation)

        model.setApprovalMode(.auto)

        let snapshot = try #require(receipt(in: model))
        #expect(snapshot.kept.count == model.kit.count)
        #expect(snapshot.kept.count > 1)                       // a real delegation, not one add
        #expect(snapshot.kept.allSatisfy { $0.part != nil })   // each names the part it answered
        // Every keep is attributed to Crumb, which is the only way the question "which of these did
        // I actually approve?" stays answerable once a kit can assemble itself.
        let decisions = try #require(model.activeThread?.decisions)
        let allCrumb = decisions.allSatisfy { $0.wasDecidedByCrumb }
        #expect(decisions.count == snapshot.kept.count)
        #expect(allCrumb)
        // Exactly one turn for the whole pass — not one line per keep, which is the run log this
        // screen deleted.
        let receipts = model.activeThread?.timeline.filter { event in
            event.blocks.contains { if case .autoKeep = $0 { true } else { false } }
        }
        #expect(receipts?.count == 1)
    }

    @Test("The card auto passed over is still asked about, with Undo alongside it")
    func passedOverCardBecomesTheNextQuestion() async throws {
        let model = await settledHikeMission()
        model.setApprovalMode(.auto)

        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .productDecision || interaction.kind == .cartReview)
        #expect(interaction.options.contains { $0.id == "undo-auto" })
        // The hard cap. A question that overruns it fails validation and takes the whole
        // transaction down, so this is arithmetic, not layout preference.
        #expect(interaction.options.count <= 4)
        // Passed over is not skipped: nothing was ruled out on the person's behalf.
        #expect(model.activeThread?.decisions.contains { $0.kind == .skipped } == false)

        // The dock folds a whole question into a "Choose a response" sheet as soon as one of its
        // options carries a detail too long to ride a capsule — `RefinementBar.hasLongDetail`, at
        // 16 characters. Undo arriving with an explanatory sentence therefore hid the question's own
        // answers behind a sheet; caught in the simulator, pinned here. A price detail is short and
        // rides fine, which is why this mirrors the length rule rather than banning details.
        let foldsTheRow = interaction.options.contains { ($0.detail?.count ?? 0) > 16 }
        #expect(!foldsTheRow)
    }

    @Test("Undo empties the kit, restores the ranked deck, and goes back to asking")
    func undoRestoresEverything() async throws {
        let model = await settledHikeMission()
        let rankedDeck = model.deck.map(\.id)
        model.setApprovalMode(.auto)
        #expect(!model.kit.isEmpty)

        model.submitMissionOption("undo-auto")

        #expect(model.kit.isEmpty)
        #expect(model.activeThread?.decisions.isEmpty == true)
        // Back in their ranked positions — the same reconstruction "Find more" does — rather than
        // shoved to the head of the queue.
        #expect(model.activeThread?.remainingDeckIDs == rankedDeck)
        // Reversing a delegation is the strongest preference signal available, so it counts as one.
        #expect(model.missionApprovalMode == .askEach)
        #expect(model.activeThread?.pendingAutoKeepUndo == nil)
        // The receipt stays: the pass really did happen, and scrollback is a record, not a claim
        // about the present.
        #expect(receipt(in: model) != nil)
        #expect(model.activeThread?.timeline.last(where: { $0.kind == .notice })?.text.contains("back") == true)
        // And the offer is gone from the question that follows.
        #expect(model.activeThread?.pendingInteraction?.options.contains { $0.id == "undo-auto" } == false)
    }

    @Test("The undo offer retires as soon as the person decides something else")
    func undoExpiresOnTheNextDecision() async throws {
        let model = await settledHikeMission()
        model.setApprovalMode(.auto)
        let interaction = try #require(model.activeThread?.pendingInteraction)
        guard case .product(let productID, _) = interaction.resolver else {
            // A deck that auto exhausted lands on the kit question instead; nothing to assert here.
            return
        }
        let submission = try #require(model.productInteractionSubmission(productID: productID, optionID: "skip"))
        model.submitMissionAnswer(submission)

        #expect(model.activeThread?.pendingAutoKeepUndo == nil)
        #expect(model.activeThread?.pendingInteraction?.options.contains { $0.id == "undo-auto" } == false)
    }

    // MARK: What it will not do

    @Test("A one-part shortlist mission is never offered delegation")
    func singlePartMissionCannotDelegate() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        let single = ShoppingTask(
            id: "tea", title: "Premium jasmine tea", subtitle: "one thing, done well",
            plan: ["Premium jasmine tea"], curatorNote: "",
            accentHex: SeedData.hike.accentHex, candidateIDs: SeedData.hikeProducts.map(\.id),
            searchQueries: ["premium jasmine tea"], isSingleItem: true
        )
        model.enterPlan(with: single)
        await model.loadCandidates(for: single)
        #expect(!model.missionAllowsDelegation)

        // Even forced on, the pass must keep nothing: the whole point of a shortlist mission is
        // that the person looks at each candidate.
        model.setApprovalMode(.auto)
        #expect(model.kit.isEmpty)
        #expect(receipt(in: model) == nil)
    }

    @Test("Turning Auto on supersedes the live question instead of answering it")
    func modeChangeIsNotAnAnswer() async throws {
        let model = await settledHikeMission()
        let before = try #require(model.activeThread?.pendingInteraction)
        guard case .product(let shownProductID, _) = before.resolver else { return }

        model.setApprovalMode(.auto)

        let after = try #require(model.activeThread?.pendingInteraction)
        #expect(after.id != before.id)
        #expect(after.interactionGeneration > before.interactionGeneration)
        // No submission was fabricated for the product the person was actually looking at: its
        // record, if any, is a Crumb keep from the pass — never a user turn quoting a chip they
        // never tapped.
        let userTurns = model.activeThread?.timeline.filter { $0.kind == .userMessage } ?? []
        #expect(userTurns.allSatisfy { $0.text != "Add" })
        #expect(model.activeThread?.decisions.contains { $0.productID == shownProductID && !$0.wasDecidedByCrumb } == false)
    }

    @Test("Find more never lets auto re-keep something the person turned down")
    func findMoreDoesNotRunTheAutoPass() async throws {
        let model = await settledHikeMission()
        // Skip the whole deck by hand, so every remaining card is one this person rejected.
        var guardRail = 0
        while let interaction = model.activeThread?.pendingInteraction,
              case .product(let productID, _) = interaction.resolver, guardRail < 40 {
            guardRail += 1
            guard let submission = model.productInteractionSubmission(productID: productID, optionID: "skip")
            else { break }
            model.submitMissionAnswer(submission)
        }
        #expect(model.kit.isEmpty)

        model.setApprovalMode(.auto)
        // Nothing to keep — the deck is empty — so the mode is armed but idle.
        #expect(model.kit.isEmpty)

        model.submitMissionOption("find-more")

        // "Find more" erases the skip record and refills the deck from the same candidates. If auto
        // ran there it would keep cards whose rejection it had just deleted the evidence of.
        #expect(model.kit.isEmpty)
        #expect(receipt(in: model) == nil)
        #expect(model.activeThread?.pendingInteraction?.kind == .productDecision)
    }

    @Test("An armed mission always shows its own switch, even when the deck runs down")
    func armedMissionKeepsItsControl() async throws {
        let model = await settledHikeMission()
        model.setApprovalMode(.auto)
        // Drive the deck to empty; `missionAllowsDelegation` goes false on the way.
        var guardRail = 0
        while let interaction = model.activeThread?.pendingInteraction,
              case .product(let productID, _) = interaction.resolver, guardRail < 40 {
            guardRail += 1
            guard let submission = model.productInteractionSubmission(productID: productID, optionID: "skip")
            else { break }
            model.submitMissionAnswer(submission)
        }
        #expect(!model.missionAllowsDelegation)
        // The setting is still on, so the control that turns it off must still be reachable —
        // otherwise the mission is delegating with nothing on screen saying so.
        #expect(model.missionApprovalMode == .auto)
    }

    @Test("Auto never opens the cart or ends the mission on its own")
    func autoTouchesNoIrreversibleAction() async throws {
        let model = await settledHikeMission()
        model.setApprovalMode(.auto)
        // Still in the mission, still conversational, nothing bought.
        #expect(model.route == .missionThread)
        #expect(model.activeThread?.phase == .deckReady)
        #expect(model.activeThread?.timeline.contains { $0.kind == .cartOpened } == false)
    }

    @Test("Switching back to Ask each stops the pass and says so")
    func modeReturnsToAsking() async throws {
        let model = await settledHikeMission()
        model.setApprovalMode(.auto)
        let keptByAuto = model.kit.count
        model.setApprovalMode(.askEach)

        #expect(model.missionApprovalMode == .askEach)
        #expect(model.kit.count == keptByAuto)      // it does not retroactively undo; Undo does that
        #expect(model.activeThread?.timeline.last(where: { $0.kind == .notice })?.text
            .contains("asking about each pick") == true)
    }
}
