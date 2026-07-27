import Testing
import Foundation
import CrumbKit
@testable import Crumb

/// Coverage for how ``AppModel/missionDockState`` presents a question.
///
/// The dock's `mode` decides whether a question is voiced neutrally or dressed in the ochre
/// `exclamationmark.icloud` treatment reserved for a failed save. ``MissionInteractionKind/retry``
/// covers two unrelated situations — a turn that genuinely failed, and a mission being asked whether
/// to pick the search back up — so the kind alone cannot carry that decision. These tests pin both
/// sides of the split, and the neutral side end-to-end through the real install path.
@Suite("Mission dock state")
struct MissionDockStateTests {

    private static func interaction(
        kind: MissionInteractionKind,
        question: String = "Want me to pick the search back up?",
        options: [MissionInteractionOption] = [MissionInteractionOption(id: "retry", label: "Resume shopping")],
        selectionMode: MissionSelectionMode = .singleChoice,
        allowsFreeText: Bool = true
    ) -> MissionPendingInteraction {
        MissionPendingInteraction(
            promptEventID: "prompt",
            interactionGeneration: 1,
            subjectRevision: 1,
            kind: kind,
            question: question,
            options: options,
            selectionMode: selectionMode,
            allowsFreeText: allowsFreeText,
            resolver: .retry(
                MissionRetryDescriptor(kind: .gathering, input: "kettle", taskRevision: 1, returnPhase: .planReady)
            ),
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: The `.retry` split

    @Test("A resumable retry with nothing queued is voiced neutrally, not as a failure")
    func retryWithoutQueuedDescriptorIsNeutral() {
        let mode = AppModel.dockMode(for: Self.interaction(kind: .retry), hasQueuedRetry: false)
        #expect(mode == .confirmation)
        #expect(mode != .recovery)
    }

    @Test("A retry standing on a real queued failure keeps the recovery treatment")
    func retryWithQueuedDescriptorIsRecovery() {
        let mode = AppModel.dockMode(for: Self.interaction(kind: .retry), hasQueuedRetry: true)
        #expect(mode == .recovery)
    }

    @Test("An explicit recovery kind is always recovery, queued or not")
    func recoveryKindIsAlwaysRecovery() {
        for queued in [true, false] {
            let mode = AppModel.dockMode(for: Self.interaction(kind: .recovery), hasQueuedRetry: queued)
            #expect(mode == .recovery)
        }
    }

    // MARK: The other registers are unchanged by the split

    @Test("A mid-work clarification offering Stop still reads as working")
    func stoppableClarificationIsWorking() {
        let mode = AppModel.dockMode(
            for: Self.interaction(
                kind: .clarification,
                question: "Searching the shops…",
                options: [MissionInteractionOption(id: "stop", label: "Stop")]
            ),
            hasQueuedRetry: false
        )
        #expect(mode == .working)
    }

    @Test("An optionless clarification is free text")
    func optionlessClarificationIsFreeText() {
        let mode = AppModel.dockMode(
            for: Self.interaction(kind: .clarification, options: []),
            hasQueuedRetry: false
        )
        #expect(mode == .freeText)
    }

    @Test("A product decision stays a single choice, and its confirmation variant a confirmation")
    func productDecisionRegisters() {
        #expect(AppModel.dockMode(
            for: Self.interaction(kind: .productDecision),
            hasQueuedRetry: false
        ) == .singleChoice)
        #expect(AppModel.dockMode(
            for: Self.interaction(kind: .productDecision, selectionMode: .confirmation),
            hasQueuedRetry: false
        ) == .confirmation)
    }

    // MARK: End to end through the real install path

    @Test("A planned mission asking to start shopping carries no failure signal in the dock")
    @MainActor
    func resumeShoppingQuestionIsNotRecovery() throws {
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.coffee)

        let state = model.missionDockState
        let pending = try #require(state.interaction)

        // The kind stays `.retry` — it carries the descriptor that actually resumes the search.
        #expect(pending.kind == .retry)
        #expect(state.question == "Should I start shopping?")
        // Nothing failed, so nothing may claim it did.
        #expect(model.activeThread?.retry == nil)
        #expect(state.mode == .confirmation)
        #expect(state.showsSaveRecovery == false)
        #expect(model.threadPersistenceWarning == nil)
    }
}
