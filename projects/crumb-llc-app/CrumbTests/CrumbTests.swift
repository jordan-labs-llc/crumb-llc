import Testing
import Foundation
import AppIntents
import CrumbKit
@testable import Crumb

/// App-level smoke tests (run via Xcode). These exercise `AppModel` routing on top of the
/// mock UCP client — no network, no secrets.
@Suite("Crumb app smoke tests")
struct CrumbTests {

    @Test("A returning user (saved profile) starts on Missions with three seed missions")
    @MainActor
    func launchesToMissions() {
        // A persisted profile is the "returning user" signal — straight to Missions.
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        #expect(model.route == .missions)
        #expect(model.missions.count == 3)
        #expect(model.kit.isEmpty)
    }

    // MARK: - Free-text planning (the composer / Siri entry)

    @Test("Planning a shoppable goal shops it immediately in its thread and records a recent")
    @MainActor
    func planShopsGoalImmediately() async {
        let recents = InMemoryRecentMissionsStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            recentsStore: recents
        )
        await model.runPlan(goal: "Set up my pour-over corner")

        #expect(model.route == .missionThread)
        #expect(model.selectedTask != nil)
        #expect(model.planDecline == nil)
        #expect(model.loadState == .loaded)             // direct: the search ran without an approval turn
        #expect(model.activeThread?.phase == .deckReady)
        #expect(!model.deck.isEmpty)
        #expect(model.recentGoals.first == "Set up my pour-over corner") // recorded, most-recent-first
    }

    @Test("A non-shopping goal declines gracefully inside its mission thread")
    @MainActor
    func planDeclinesNonShoppingGoal() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "what is the weather?")

        #expect(model.route == .missionThread)         // the decline remains a retryable conversation
        #expect(model.selectedTask == nil)
        #expect(model.planDecline != nil)              // a friendly message instead
        #expect(model.recentGoals.isEmpty)             // nonsense isn't remembered
    }

    // MARK: - Onboarding "let the goal lead" fast path (#28)

    @Test("A first-run user can start from a goal: it opens a mission thread and persists a profile")
    @MainActor
    func goalFirstOnboardingRoutesToThread() async {
        let store = InMemoryTasteStore()   // no saved profile → first-run onboarding
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        #expect(model.route == .onboarding)

        await model.runOnboardingGoal("Set up my pour-over corner")

        #expect(model.route == .missionThread)         // led straight into the shopping thread
        #expect(model.selectedTask != nil)
        #expect(store.loadProfile() != nil)            // onboarding completed + persisted (won't reappear)
    }

    @Test("A first-run user is seeded with taste inferred from the goal")
    @MainActor
    func goalFirstSeedsTasteFromGoal() async {
        let store = InMemoryTasteStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: store, tasteExtractor: MarkerTasteExtractor()
        )
        await model.runOnboardingGoal("Set up my pour-over corner")

        // The injected extractor read the goal into the profile — the goal-first path wired it in.
        #expect(model.tasteProfile.vibe.contains("GoalSeeded"))
        #expect(store.loadProfile()?.vibe.contains("GoalSeeded") == true)
    }

    @Test("A first-run user with a non-shoppable goal still finishes onboarding, not stranded")
    @MainActor
    func goalFirstNonShoppableCompletesOnboarding() async {
        let store = InMemoryTasteStore()
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)

        await model.runOnboardingGoal("what is the weather?")

        #expect(model.route == .missionThread)         // decline is shown in a retryable thread
        #expect(model.selectedTask == nil)
        #expect(model.planDecline != nil)              // the friendly decline, shown in the thread
        #expect(store.loadProfile() != nil)            // onboarding still persisted
    }

    @Test("Editing the plan then curating searches in the same mission thread")
    @MainActor
    func editPlanThenCurate() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "Set up my pour-over corner")
        let firstPart = try! #require(model.draftParts.first)
        model.updatePart(firstPart, label: "gooseneck kettle")    // reword → re-derives the query
        model.addPart(label: "burr coffee grinder")

        await model.beginCuration()

        #expect(model.route == .missionThread)
        #expect(model.loadState == .loaded)
        #expect(!model.candidates.isEmpty)             // the mock resolved the edited queries
    }

    @Test("Removing a part drops it from the draft plan")
    @MainActor
    func removePart() async {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: SeedData.desk)
        let count = model.draftParts.count
        let part = try! #require(model.draftParts.first)
        model.removePart(part)
        #expect(model.draftParts.count == count - 1)
        #expect(!model.draftParts.contains(part))
    }

    @Test("The final plan part cannot be removed")
    @MainActor
    func keepFinalPlanPart() async {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        await model.runPlan(goal: "Make my desk feel calm")
        #expect(model.draftParts.count == 1)
        let part = try! #require(model.draftParts.first)
        model.removePart(part)
        #expect(model.draftParts == [part])
    }

    @Test("Accepting a product in a thread adds it to the kit and timeline once")
    @MainActor
    func acceptBuildsKit() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let product = try #require(model.deck.first)
        model.accept(product)
        model.accept(product) // idempotent by product id
        #expect(model.kit.count == 1)
        #expect(model.isInKit(product))
        #expect(model.activeThread?.decisions.filter { $0.kind == .added }.count == 1)
        #expect(model.activeThread?.timeline.filter { $0.kind == .productAdded }.count == 1)
    }

    // MARK: - Durable mission threads

    @Test("Planning creates a durable thread with a semantic timeline")
    @MainActor
    func planningCreatesThreadTimeline() async throws {
        let threadStore = InMemoryMissionThreadStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            threadStore: threadStore
        )

        await model.runPlan(goal: "Set up my pour-over corner")

        let thread = try #require(model.activeThread)
        #expect(model.route == .missionThread)
        #expect(thread.originalGoal == "Set up my pour-over corner")
        #expect(thread.phase == .deckReady)             // direct: planning flows straight into the deck
        #expect(thread.timeline.map(\.kind).contains(.userMessage))
        #expect(thread.timeline.map(\.kind).contains(.planningStarted))
        #expect(thread.timeline.map(\.kind).contains(.gatheringStarted))
        #expect(thread.timeline.map(\.kind).contains(.gatheringCompleted))
        #expect(thread.timeline.map(\.sequence) == Array(0..<thread.timeline.count))
        #expect(threadStore.load().threads.first?.id == thread.id)
    }

    // MARK: - Direct missions (no plan step — the orchestrator decides the catalog calls)

    @Test("Planning never installs a plan approval — the first durable question is the deck's")
    @MainActor
    func planningSkipsPlanApproval() async throws {
        let store = InMemoryMissionThreadStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile), threadStore: store
        )

        // A goal the mock catalog resolves (matches the pour-over seed mission); the live
        // jasmine-tea scenario is exercised against the real broker on the simulator.
        await model.runPlan(goal: "pour-over kettle")

        #expect(model.route == .missionThread)
        #expect(model.selectedTask != nil)
        #expect(model.loadState == .loaded)
        #expect(model.activeThread?.phase == .deckReady)
        #expect(!model.deck.isEmpty)
        // No plan-approval turn ever appears — the pending question is the deck's, not the plan's.
        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind != .planApproval)
        // A single-intent goal posts no plan notice either — the deck is the first artifact.
        #expect(model.activeThread?.timeline.contains { $0.kind == .planReady } == false)
        #expect(model.recentGoals.first == "pour-over kettle")
        #expect(store.load().threads.first?.pendingInteraction == interaction)
    }

    @Test("A failed gather lands on a retry question, never a plan approval")
    @MainActor
    func gatherFailureOffersRetry() async throws {
        let model = AppModel(
            ucp: UnconfiguredUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "pour-over kettle")

        #expect(model.loadState == .failed)
        #expect(model.activeThread?.phase == .failed)
        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .retry)
        #expect(model.activeThread?.timeline.contains { $0.kind == .planReady } == false)
    }

    @Test("A non-shopping goal still declines inside the direct chain")
    @MainActor
    func directChainStillDeclines() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "what is the weather?")

        #expect(model.selectedTask == nil)
        #expect(model.planDecline != nil)
        #expect(model.activeThread?.phase == .declined)
    }

    @Test("A kit-cue goal keeps its deterministic plan as an in-thread notice, never an approval turn")
    @MainActor
    func kitGoalPostsPlanNoticeAndShopsImmediately() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "lacrosse gear for my son")

        // The deterministic player kit survived as the mission's plan…
        #expect((model.selectedTask?.plan.count ?? 0) >= 4)
        #expect(model.selectedTask?.isSingleItem == false)
        // …surfaced as a read-only timeline notice carrying the stated assumption + the parts…
        let notice = try #require(model.activeThread?.timeline.first { $0.kind == .planReady })
        #expect(notice.text.localizedCaseInsensitiveContains("field player"))
        #expect(notice.blocks.contains { if case .plan = $0 { return true } else { return false } })
        // …and the search started without a blocking approval turn.
        #expect(model.activeThread?.pendingInteraction?.kind != .planApproval)
        #expect(model.activeThread?.timeline.map(\.kind).contains(.gatheringStarted) == true)
    }

    @Test("Free text typed mid-search buffers and applies as a refinement once the deck settles (no wedge)")
    @MainActor
    func midGatherTextBuffersThenRefines() async throws {
        let model = AppModel(
            ucp: MockUCPClient(simulatedLatency: 200_000_000), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(priceDirection: .cheaper))
        )
        model.enterPlan(with: SeedData.hike)
        let load = Task { @MainActor in await model.loadCandidates(for: SeedData.hike) }
        for _ in 0..<200 where model.activeThread?.pendingInteraction?.question != "Searching the shops…" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.activeThread?.pendingInteraction?.question == "Searching the shops…")

        model.submitMissionText("under $50")

        // The gather was NOT cancelled into a rework: the text is queued and acknowledged.
        #expect(model.activeThread?.queuedRefinements == ["under $50"])
        #expect(model.isReworking == false)
        #expect(model.activeThread?.pendingInteraction?.allowsFreeText == true)   // still conversational

        await load.value

        // The buffered text ran as a refinement after settle — no stuck "Reworking the picks…".
        #expect(model.refinementTurns == ["under $50"])
        #expect((model.activeThread?.queuedRefinements ?? []).isEmpty)
        #expect(model.loadState == .loaded)
        #expect(model.isReworking == false)
        #expect(model.activeThread?.pendingInteraction != nil)
        let prices = model.deck.map(\.price)
        #expect(prices == prices.sorted(by: <))   // the cheaper directive visibly applied
    }

    @Test("Stop mid-search offers a resume-shopping confirmation — never a plan approval — and resume re-gathers")
    @MainActor
    func stopMidGatherOffersResume() async throws {
        let model = AppModel(
            ucp: MockUCPClient(simulatedLatency: 200_000_000), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        let load = Task { @MainActor in await model.loadCandidates(for: SeedData.hike) }
        for _ in 0..<200 where model.activeThread?.pendingInteraction?.question != "Searching the shops…" {
            try await Task.sleep(for: .milliseconds(5))
        }

        // Text typed just before Stop is buffered; Stop must set it aside honestly (never a
        // silent drop, never a surprise application on a much-later re-gather).
        model.submitMissionText("under $50")
        #expect(model.activeThread?.queuedRefinements == ["under $50"])

        model.submitMissionOption("stop")

        #expect((model.activeThread?.queuedRefinements ?? []).isEmpty)
        #expect(model.activeThread?.timeline.contains {
            $0.kind == .notice && $0.text.contains("set aside")
        } == true)
        #expect(model.activeThread?.phase == .planReady)
        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .retry)                          // resume confirmation…
        #expect(interaction.kind != .planApproval)                   // …not the removed approval turn
        #expect(interaction.options.map(\.id) == ["retry", "cancel"])
        #expect(interaction.options.first?.label == "Resume shopping")
        await load.value                                              // the stopped load exits quietly
        #expect(model.activeThread?.phase == .planReady)              // its late settle was rejected

        model.submitMissionOption("retry")
        for _ in 0..<400 where model.loadState != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.loadState == .loaded)
        #expect(model.activeThread?.phase == .deckReady)
        #expect(!model.deck.isEmpty)
    }

    @Test("Retrying a crash-interrupted gather re-runs the search instead of wedging (recovered deck)")
    @MainActor
    func recoveredGatherRetryRegathers() async throws {
        // A thread persisted mid-gather WITH streamed candidates — the crash-recovery state
        // whose resume (loadState .loaded, planDirty false, candidates non-empty) used to
        // satisfy beginCuration's reuse shortcut and wedge the retry behind a working
        // question with nothing running.
        let store = InMemoryMissionThreadStore()
        let task = SeedData.hike
        let products = SeedData.hikeProducts
        var thread = MissionThread(goal: task.title, taste: SeedData.defaultTasteProfile, now: Date())
        thread.task = task
        thread.plan = task.plan.enumerated().map { index, label in
            MissionPlanPart(label: label, query: index < task.searchQueries.count ? task.searchQueries[index] : label)
        }
        thread.phase = .gathering
        thread.candidates = products
        thread.baseCandidates = products
        thread.remainingDeckIDs = products.map(\.id)
        thread.appendEvent(kind: .userMessage, text: task.title, createdAt: Date())
        thread.pendingOperation = MissionPendingOperation(
            retry: MissionRetryDescriptor(
                kind: .gathering, input: task.searchQueries.joined(separator: "\n"),
                taskRevision: thread.revision, returnPhase: .planReady
            ),
            startedAt: Date()
        )
        try store.save(thread)

        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile), threadStore: store
        )
        let persisted = try #require(model.incompleteThreads.first)
        model.resumeThread(persisted)
        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .retry)

        model.submitMissionOption("retry")
        for _ in 0..<400 where model.activeThread?.pendingOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.activeThread?.pendingOperation == nil)   // the retry genuinely re-ran
        #expect(model.loadState == .loaded)
        #expect(model.activeThread?.phase == .deckReady)
        let next = try #require(model.activeThread?.pendingInteraction)
        #expect(next.kind == .productDecision || next.kind == .cartReview)  // never a dead working question
    }

    @Test("A product answer is idempotent and advances to exactly one next question")
    @MainActor
    func productReducerIsIdempotent() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let product = try #require(model.deck.first)
        let submission = try #require(model.productInteractionSubmission(productID: product.id, optionID: "add"))

        model.submitMissionAnswer(submission)
        model.submitMissionAnswer(submission)

        #expect(model.kit.map(\.product.id) == [product.id])
        #expect(model.activeThread?.decisions.filter { $0.id == submission.idempotencyID }.count == 1)
        #expect(model.activeThread?.pendingInteraction != nil)
        #expect(model.activeThread?.pendingInteraction?.id != submission.interactionID)
    }

    /// A pick question shows Crumb's recommendation beside the two foils that make it legible, and
    /// names them with their prices. "Show another" retires when foils are present: the foils *are*
    /// the other options, shown rather than promised. It still appears when there is nothing to
    /// compare against, and the reducer still honors it for threads persisted before this change.
    @Test("A pick question offers its alternatives by name and price, not a generic 'show another'")
    @MainActor
    func pickQuestionNamesItsAlternatives() async throws {
        // Single-item: only there is the deck an apples-to-apples set. See `AppModel.foils(for:in:)`.
        let mission = SeedData.hike.settingSingleItem(true)
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: mission)
        await model.loadCandidates(for: mission)

        let interaction = try #require(model.activeThread?.pendingInteraction)
        let ids = interaction.options.map(\.id)
        #expect(ids.contains("add"))
        #expect(ids.contains("skip"), "rejecting the pick must always be one tap")
        #expect(interaction.options.count <= 4, "the interaction contract caps a question at four")

        let foilChips = interaction.options.filter { $0.id.hasPrefix("foil:") }
        #expect(!foilChips.isEmpty, "the seed deck has alternatives worth naming")
        #expect(!ids.contains("show-another"), "foils replace the generic offer")
        for chip in foilChips {
            #expect(chip.label == "Cheaper" || chip.label == "Nicer")
            #expect(chip.detail?.isEmpty == false, "an alternative must say what it costs")
        }
    }

    /// Choosing an alternative is a *look*, not a purchase: it becomes the recommendation and is
    /// asked again with its own card and reason, so no tap on a price ever buys something.
    @Test("Choosing an alternative promotes it without kitting it")
    @MainActor
    func choosingAFoilPromotesIt() async throws {
        let mission = SeedData.hike.settingSingleItem(true)
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: mission)
        await model.loadCandidates(for: mission)

        let interaction = try #require(model.activeThread?.pendingInteraction)
        let foilChip = try #require(interaction.options.first { $0.id.hasPrefix("foil:") })
        let foilID = String(foilChip.id.dropFirst("foil:".count))

        model.submitMissionOption(foilChip.id)

        #expect(model.kit.isEmpty, "looking at an alternative must never add it")
        #expect(model.activeThread?.decisions.isEmpty == true, "and must not record a decision")
        let next = try #require(model.activeThread?.pendingInteraction)
        #expect(next.kind == .productDecision)
        guard case .product(let asked, _) = next.resolver else {
            Issue.record("expected a product question, got \(next.resolver)")
            return
        }
        #expect(asked == foilID, "the alternative is now the recommendation")
    }

    @Test("Typed write intent acts immediately — the frozen question makes 'add it' as unambiguous as the chip")
    @MainActor
    func typedAddActsImmediately() async throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let product = try #require(model.deck.first)
        let interaction = try #require(model.activeThread?.pendingInteraction)
        model.submitMissionAnswer(MissionInteractionSubmission(
            threadID: try #require(model.activeThreadID), interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision, answer: .freeText("add it")
        ))

        // No confirmation detour: the kit mutated once and the conversation moved on.
        #expect(model.kit.map(\.product.id) == [product.id])
        #expect(model.activeThread?.pendingInteraction?.selectionMode != .confirmation)
        #expect(model.activeThread?.timeline.contains { $0.kind == .productAdded && $0.productID == product.id } == true)
    }

    @Test("Natural answers to the product question resolve like their chips")
    @MainActor
    func naturalProductAnswersResolveLikeChips() async throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let first = try #require(model.deck.first)

        // "Looks good." — trailing punctuation and case are forgiven — adds the frozen product.
        var interaction = try #require(model.activeThread?.pendingInteraction)
        model.submitMissionAnswer(MissionInteractionSubmission(
            threadID: try #require(model.activeThreadID), interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision, answer: .freeText("Looks good.")
        ))
        #expect(model.kit.map(\.product.id) == [first.id])

        // "No thanks" skips the next one.
        let second = try #require(model.deck.first)
        interaction = try #require(model.activeThread?.pendingInteraction)
        model.submitMissionAnswer(MissionInteractionSubmission(
            threadID: try #require(model.activeThreadID), interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision, answer: .freeText("No thanks")
        ))
        #expect(model.activeThread?.decisions.contains { $0.productID == second.id && $0.kind == .skipped } == true)

        // "Show me another" rotates without recording a skip.
        let third = try #require(model.deck.first)
        interaction = try #require(model.activeThread?.pendingInteraction)
        model.submitMissionAnswer(MissionInteractionSubmission(
            threadID: try #require(model.activeThreadID), interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision, answer: .freeText("show me another")
        ))
        #expect(model.activeThread?.decisions.contains { $0.productID == third.id && $0.kind == .skipped } == false)
        if model.deck.count > 1 { #expect(model.deck.last?.id == third.id) }
    }

    @Test("A refinement's follow-ups ride the next product question, then step aside")
    @MainActor
    func refinementFollowUpsAppearOnce() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(priceDirection: .cheaper))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)

        model.submitMissionText("make it cheaper")
        for _ in 0..<400 where model.isReworking || model.activeThread?.pendingOperation != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        let refined = try #require(model.activeThread?.pendingInteraction)
        #expect(refined.kind == .productDecision)
        // One contextual chip, and never more than the four-option interaction contract allows.
        #expect(refined.options.map(\.id).contains("save-to-taste"))
        #expect(refined.options.count <= 4)

        // Answering normally clears the contextual follow-up from the next question.
        model.submitMissionOption("skip")
        let next = try #require(model.activeThread?.pendingInteraction)
        #expect(next.options.map(\.id).contains("save-to-taste") == false)
    }

    @Test("Planning the same goal twice creates distinct mission threads")
    @MainActor
    func sameGoalCreatesDistinctThreads() async throws {
        let threadStore = InMemoryMissionThreadStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            threadStore: threadStore
        )

        await model.runPlan(goal: "Set up my pour-over corner")
        let firstID = try #require(model.activeThreadID)
        await model.runPlan(goal: "Set up my pour-over corner")
        let secondID = try #require(model.activeThreadID)

        #expect(firstID != secondID)
        #expect(Set(threadStore.load().threads.map(\.id)) == [firstID, secondID])
    }

    @Test("Committing an edited direct-product plan preserves single-item framing")
    @MainActor
    func rebuiltPlanPreservesSingleItem() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        let direct = ShoppingTask(
            id: "direct.coffee", title: "Find a coffee grinder", subtitle: "Compare a few options",
            plan: ["Coffee grinder"], curatorNote: "One product, several choices.", accentHex: 0,
            candidateIDs: [], searchQueries: ["coffee grinder"], isSingleItem: true
        )
        model.enterPlan(with: direct)
        let part = try #require(model.draftParts.first)
        model.updatePart(part, label: "quiet burr coffee grinder")

        await model.beginCuration()

        #expect(model.route == .missionThread)
        #expect(model.selectedTask?.isSingleItem == true)
        #expect(model.isSingleProductMission)
    }

    @Test("A second AppModel resumes the persisted thread without rebuilding its state")
    @MainActor
    func resumesPersistedThread() async throws {
        let threadStore = InMemoryMissionThreadStore()
        let tasteStore = InMemoryTasteStore(SeedData.defaultTasteProfile)
        let first = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: tasteStore, threadStore: threadStore
        )
        await first.runPlan(goal: "Set up my pour-over corner")
        await first.beginCuration()
        let product = try #require(first.deck.first)
        first.accept(product)
        let savedID = try #require(first.activeThreadID)
        let savedDeck = first.deck.map(\.id)
        let savedTimeline = try #require(first.activeThread?.timeline)
        let savedInteraction = try #require(first.activeThread?.pendingInteraction)

        let relaunched = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: tasteStore, threadStore: threadStore
        )
        let persisted = try #require(relaunched.incompleteThreads.first { $0.id == savedID })
        relaunched.resumeThread(persisted)

        #expect(relaunched.route == .missionThread)
        #expect(relaunched.activeThreadID == savedID)
        #expect(relaunched.kit.map(\.product.id) == [product.id])
        #expect(relaunched.deck.map(\.id) == savedDeck)
        #expect(relaunched.activeThread?.timeline == savedTimeline)
        #expect(relaunched.activeThread?.pendingInteraction == savedInteraction)
        #expect(relaunched.loadState == .loaded)
    }

    @Test("MockUCPClient.searchCatalog(\"hike\") returns the hike candidates")
    func searchHike() async throws {
        let hits = try await MockUCPClient().searchCatalog("hike", placements: [.organic])
        #expect(hits.count == 6)
        #expect(hits.allSatisfy { $0.id.hasPrefix("hike.") })
    }

    @Test("A mission's search queries all resolve to its curated deck (mock fan-out)")
    func mockResolvesSearchQueries() async throws {
        let mock = MockUCPClient()
        for query in SeedData.hike.searchQueries {
            let hits = try await mock.searchCatalog(query, placements: [.organic])
            #expect(hits.allSatisfy { $0.id.hasPrefix("hike.") }, "query: \(query)")
            #expect(!hits.isEmpty, "query: \(query)")
        }
    }

    @Test("loadCandidates fans queries out in parallel and dedupes by product id")
    @MainActor
    func fanOutDedupes() async {
        let p1 = Self.fakeProduct("a")
        let p2 = Self.fakeProduct("b")
        let p3 = Self.fakeProduct("c")
        let fake = FakeUCP(byQuery: [
            "q1": [p1, p2],
            "q2": [p2, p3],   // p2 overlaps q1 — must dedupe to one
        ])
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .loaded)
        #expect(model.candidates.count == 3)
        #expect(Set(model.candidates.map(\.id)) == ["a", "b", "c"])
    }

    @Test("A query that errors still contributes its siblings' results")
    @MainActor
    func partialFailureKeepsResults() async {
        let fake = FakeUCP(byQuery: ["q1": [Self.fakeProduct("a")]], failing: ["q2"])
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .loaded)
        #expect(model.candidates.map(\.id) == ["a"])
    }

    @Test("When every query errors, the load fails (distinct from empty)")
    @MainActor
    func allFailuresSurfaceError() async {
        let fake = FakeUCP(byQuery: [:], failAll: true)
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .failed)
        #expect(model.loadFailed)
        #expect(model.candidates.isEmpty)
    }

    @Test("Streaming curate keeps the mission thread mounted and settles to the ranked deck")
    @MainActor
    func streamingLoadSettlesToRankedDeck() async {
        // A seed mission on the mock: picks stream in, we navigate to Curate on the first, then the
        // deck settles to the curator's ranked order once curation finishes.
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(),
                             tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile))
        model.enterPlan(with: SeedData.coffee)   // sets selectedTask + route = .missionThread
        await model.loadCandidates(for: SeedData.coffee)

        #expect(model.route == .missionThread)          // the workspace stays mounted across phases
        #expect(model.loadState == .loaded)             // then settled
        #expect(!model.deck.isEmpty)
        // No swipes happened, so the settled deck is the full ranked deck — same set and order as
        // the curated candidates.
        #expect(model.deck.map(\.id) == model.candidates.map(\.id))
        #expect(Set(model.deck.map(\.id)) == Set(SeedData.coffeeProducts.map(\.id)))
    }

    @Test("First streamed pick flips loadState from loading to refining, then settles to loaded (#57)")
    @MainActor
    func firstPickEntersRefiningThenSettles() async {
        // A slow curator keeps the settle running long enough that the deck is genuinely actionable
        // (refining) before it settles — the state the indefinite-spinner bug lived in.
        let model = AppModel(ucp: MockUCPClient(), curator: DelayingCurator(delay: .milliseconds(150)),
                             tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile))
        model.enterPlan(with: SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)
        // By the time the call returns we've settled; the deck is the model-ranked one (not fallback).
        #expect(model.loadState == .loaded)
        #expect(model.route == .missionThread)
        #expect(!model.deck.isEmpty)
        #expect(model.curatorTier == .onDevice)          // the slow curation completed in time
        #expect(model.curationRefiningOvertime == false) // reset on settle
    }

    @Test("A curation that overruns the settle deadline settles the streamed deck, not a spinner (#57)")
    @MainActor
    func settleDeadlineFallsBackToStreamedDeck() async {
        // The curator stalls well past the (shrunk) hard deadline — the load must still settle with
        // the streamed, deterministically-voiced deck instead of hanging in `.refining` forever.
        let model = AppModel(ucp: MockUCPClient(), curator: DelayingCurator(delay: .seconds(5)),
                             tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile))
        model.curationSettleWindow = 0.02
        model.curationSettleDeadline = 0.1
        model.enterPlan(with: SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)

        #expect(model.loadState == .loaded)                        // settled, never stuck refining
        #expect(model.route == .missionThread)
        #expect(!model.deck.isEmpty)                               // the streamed deck is usable
        // A timeout is its own reason. The curator was available and ran — it just overran — so the
        // tier must not be `.modelNotReady`, whose copy claims a download is still in flight.
        #expect(model.curatorTier == .ruleBased(.rankTimedOut))
        #expect(model.curatorFallbackNote?.contains("too long") == true)
        #expect(model.curatorFallbackNote?.contains("downloading") == false)
    }

    @Test("kitCompleteness flags a partial kit and stays nil for a single-product mission (#67)")
    @MainActor
    func kitCompletenessGuardsCheckout() async {
        func named(_ id: String, _ name: String) -> Product {
            Product(id: id, name: name, shop: Shop(id: "s", name: "Shop"), price: 20, rating: 0,
                    reviews: 0, rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
                    variants: [Variant(id: "\(id).v", title: "Standard", price: 20)])
        }
        let stick = named("s1", "Lacrosse Stick")
        let model = AppModel(
            ucp: FakeUCP(byQuery: ["lacrosse stick": [stick]]),
            curator: RuleBasedCurator()
        )
        let kitTask = ShoppingTask(
            id: "lax", title: "Lacrosse gear", subtitle: "",
            plan: ["Lacrosse stick", "Gloves", "Helmet", "Cleats"],
            curatorNote: "", accentHex: 0, candidateIDs: [], searchQueries: ["lacrosse stick"],
            isSingleItem: false
        )
        model.enterPlan(with: kitTask)
        await model.loadCandidates(for: kitTask)
        model.submitMissionOption("add")   // covers only "Lacrosse stick"

        let completeness = model.kitCompleteness
        #expect(completeness != nil)
        #expect(completeness?.isComplete == false)
        #expect(completeness?.missing == ["Gloves", "Helmet", "Cleats"])

        // A single-product shortlist mission never gets a completeness panel.
        model.enterPlan(with: kitTask.settingSingleItem(true))   // resets the kit
        await model.loadCandidates(for: kitTask.settingSingleItem(true))
        model.submitMissionOption("add")
        #expect(model.kitCompleteness == nil)
    }

    @Test("A total catalog outage fails without navigating away from the mission thread")
    @MainActor
    func streamingOutageStaysInThread() async {
        let fake = FakeUCP(byQuery: [:], failAll: true)
        let task = Self.fakeTask(queries: ["q1", "q2"])
        let model = AppModel(ucp: fake, curator: RuleBasedCurator())
        model.enterPlan(with: task)
        await model.loadCandidates(for: task)

        #expect(model.loadState == .failed)
        #expect(model.deck.isEmpty)
        #expect(model.route == .missionThread)
    }

    @Test("settledDeck keeps undecided cards in ranked order and drops swiped-away ones")
    func settledDeckShaping() {
        let settled = [Self.fakeProduct("a"), Self.fakeProduct("b"),
                       Self.fakeProduct("c"), Self.fakeProduct("d")]   // ranked order
        // The user swiped a and d away while streaming; b and c remain (c is on top).
        let current = [Self.fakeProduct("c"), Self.fakeProduct("b")]
        let out = AppModel.settledDeck(settled, keepingUndecidedFrom: current)
        #expect(out.map(\.id) == ["b", "c"])   // undecided only, in the settled (ranked) order — not floated
        // Nothing streamed yet → the full ranked deck is used unchanged.
        #expect(AppModel.settledDeck(settled, keepingUndecidedFrom: []).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test("beginHandoff presents the sheet with a nil url when no link resolves")
    @MainActor
    func handoffPresentsHonestSheet() async {
        // FakeUCP always throws emptyShopHandoff — the sheet must still present (no silent
        // no-op), carrying a nil url so the view can show the honest "no link" state.
        let model = AppModel(ucp: FakeUCP(byQuery: [:]), curator: RuleBasedCurator())
        let product = Self.fakeProduct("a")
        model.enterPlan(with: Self.fakeTask(queries: []))
        model.accept(product)

        await model.beginHandoff(for: product.shop)

        let handoff = model.handoff
        #expect(handoff != nil)
        #expect(handoff?.url == nil)
        #expect(handoff?.items.count == 1)
    }

    @Test("Single-item handoff checks out exactly one product, even when options share a shop (#60)")
    @MainActor
    func singleItemHandoffIsolatesOneProduct() async throws {
        // Both fake products live in the same shop; the per-shop handoff would take both, but the
        // single-product "Buy this" must carry only the one the user chose.
        let model = AppModel(ucp: FakeUCP(byQuery: [:]), curator: RuleBasedCurator())
        model.enterPlan(with: Self.fakeTask(queries: []))
        model.accept(Self.fakeProduct("a"))
        model.accept(Self.fakeProduct("b"))
        #expect(model.currentCart.items(for: Shop(id: "s", name: "Shop")).count == 2)

        let itemA = try #require(model.kit.first { $0.product.id == "a" })
        await model.beginHandoff(for: itemA)

        let handoff = try #require(model.handoff)
        #expect(handoff.items.count == 1)
        #expect(handoff.items.first?.product.id == "a")
        #expect(handoff.shop.id == "s")
        #expect(handoff.url == nil)   // FakeUCP resolves no link — still presents honestly
    }

    @Test("Multi-store checkout prepares every merchant independently")
    @MainActor
    func multiStoreCheckoutPreparesEveryMerchant() async throws {
        let client = CheckoutRecordingUCP()
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        let products = Self.productsFromDistinctShops(count: 2)
        #expect(products.count == 2)
        model.enterPlan(with: Self.fakeTask(queries: []))
        products.forEach(model.accept)

        await model.startCheckoutWorkflow()

        let workflow = try #require(model.checkoutWorkflow)
        #expect(workflow.merchants.count == 2)
        #expect(workflow.preparedCount == 2)
        #expect(workflow.merchants.allSatisfy { $0.state.isPrepared })
        #expect(await client.callCount() == 2)
    }

    @Test("Merchant retry reuses its idempotency key and does not retry other shops")
    @MainActor
    func checkoutRetryIsTargetedAndIdempotent() async throws {
        let products = Self.productsFromDistinctShops(count: 2)
        let failedShop = try #require(products.first?.shop)
        let client = CheckoutRecordingUCP(failFirstFor: failedShop.id)
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        model.enterPlan(with: Self.fakeTask(queries: []))
        products.forEach(model.accept)

        await model.startCheckoutWorkflow()
        let before = try #require(model.checkoutWorkflow)
        let originalKey = try #require(before.merchants.first { $0.shop.id == failedShop.id }?.idempotencyKey)
        await model.retryCheckout(for: failedShop)

        let failedShopCalls = await client.calls(for: failedShop.id)
        #expect(failedShopCalls == [originalKey, originalKey])
        let otherShop = try #require(products.last?.shop)
        #expect(await client.calls(for: otherShop.id).count == 1)
        #expect(model.checkoutWorkflow?.preparedCount == 2)
    }

    @Test("Single-product checkout contains only the selected alternative")
    @MainActor
    func singleProductUsesOneItemCheckoutWorkflow() async throws {
        let client = CheckoutRecordingUCP()
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        let product = Self.fakeProduct("selected")
        let item = KitItem(product: product)

        await model.startCheckoutWorkflow(for: item)

        let workflow = try #require(model.checkoutWorkflow)
        #expect(workflow.merchants.count == 1)
        #expect(workflow.merchants[0].items.map(\.id) == ["selected"])
        #expect(await client.itemIDs(for: product.shop.id) == ["selected"])
    }

    @Test("Workflow keys are fixed length and terminal sessions are not counted ready")
    @MainActor
    func checkoutKeysAndTerminalStateAreHonest() async throws {
        let client = CheckoutRecordingUCP(status: .canceled)
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        let product = Self.fakeProduct("p")
        await model.startCheckoutWorkflow(for: KitItem(product: product))

        let merchant = try #require(model.checkoutWorkflow?.merchants.first)
        #expect(merchant.idempotencyKey.count == 42)
        #expect(model.checkoutWorkflow?.preparedCount == 0)
        #expect(!merchant.state.isPrepared)
    }

    @Test("Native sandbox checkout updates, reviews, and completes without history persistence")
    @MainActor
    func nativeSandboxLifecycle() async throws {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        let item = KitItem(product: SeedData.coffeeProducts[0])
        await model.startCheckoutWorkflow(for: item)
        let shop = item.product.shop
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .contact)

        model.editSandboxCheckout(for: shop) {
            $0.firstName = "Sample"; $0.lastName = "Shopper"
            $0.email = "sample@example.invalid"; $0.street = "1 Sandbox Way"
            $0.city = "Testville"; $0.region = "CA"; $0.postalCode = "94107"
        }
        await model.submitSandboxContact(for: shop)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .shipping)
        model.editSandboxCheckout(for: shop) {
            $0.shippingSelections["shipment_1"] = "standard"
            $0.updateKey = nil
        }
        await model.submitSandboxContact(for: shop)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .review)
        guard case .prepared(let reviewed) = try #require(model.checkoutWorkflow?.merchants.first?.state) else {
            Issue.record("Expected reviewed sandbox session")
            return
        }
        #expect(reviewed.fulfillmentGroups.first?.selectedOptionID != nil)

        model.acknowledgeSandboxReview(for: shop, acknowledged: true)
        await model.completeSandboxCheckout(for: shop)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .completed)
        guard case .prepared(let completed) = try #require(model.checkoutWorkflow?.merchants.first?.state) else {
            Issue.record("Expected completed sandbox session")
            return
        }
        #expect(completed.status == .completed)
        #expect(completed.order?.id.hasPrefix("SANDBOX-") == true)
        #expect(model.historyEntries.isEmpty)

        // A second tap after completion is ignored by the phase guard.
        await model.completeSandboxCheckout(for: shop)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .completed)
    }

    @Test("Dirty shipping cannot complete until merchant totals are updated and reviewed")
    @MainActor
    func dirtySandboxReviewCannotComplete() async throws {
        let client = MockUCPClient()
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        let item = KitItem(product: SeedData.coffeeProducts[0])
        await model.startCheckoutWorkflow(for: item)
        let shop = item.product.shop
        model.mutateSandboxPayload(for: shop) {
            $0.firstName = "Sample"; $0.lastName = "Shopper"; $0.email = "s@example.invalid"
            $0.street = "1 Test St"; $0.city = "Town"; $0.region = "CA"; $0.postalCode = "94107"
        }
        await model.submitSandboxContact(for: shop)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .shipping)
        await model.completeSandboxCheckout(for: shop) // incomplete sessions cannot complete
        model.mutateSandboxPayload(for: shop) { $0.shippingSelections["shipment_1"] = "standard" }
        await model.submitSandboxContact(for: shop)
        model.mutateSandboxPayload(for: shop) { $0.shippingSelections["shipment_1"] = "express" }
        model.acknowledgeSandboxReview(for: shop, acknowledged: true)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.isDirty == true)
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.isAcknowledged == false)
        await model.completeSandboxCheckout(for: shop)
        guard case .prepared(let session) = try #require(model.checkoutWorkflow?.merchants.first?.state) else { return }
        #expect(session.status == .readyForComplete)
        #expect(session.order == nil)
    }

    @Test("Closing checkout discards sandbox session and transient PII")
    @MainActor
    func closeDiscardsSandbox() async throws {
        let client = MockUCPClient()
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        await model.startCheckoutWorkflow(for: KitItem(product: SeedData.coffeeProducts[0]))
        guard case .prepared(let session) = try #require(model.checkoutWorkflow?.merchants.first?.state) else { return }
        model.closeCheckoutWorkflow()
        #expect(model.checkoutWorkflow == nil)
        // Discard is best-effort asynchronous; yield until the actor-backed mock observes it.
        for _ in 0..<20 {
            if (try? await client.getCheckout(id: session.id)) == nil { break }
            await Task.yield()
        }
        await #expect(throws: UCPError.self) { _ = try await client.getCheckout(id: session.id) }
    }

    @Test("Expired sandbox is not ready and requests a fresh session")
    @MainActor
    func expiredSandboxState() async throws {
        let now = Date()
        let client = MockUCPClient(checkoutConfiguration: .init(
            now: now, clock: { now }, expiresImmediately: true
        ))
        let model = AppModel(ucp: client, curator: RuleBasedCurator())
        await model.startCheckoutWorkflow(for: KitItem(product: SeedData.coffeeProducts[0]))
        #expect(model.checkoutWorkflow?.merchants.first?.sandbox?.phase == .expired)
        #expect(model.checkoutWorkflow?.preparedCount == 0)
    }

    private static func productsFromDistinctShops(count: Int) -> [Product] {
        var seen = Set<Shop.ID>()
        return SeedData.products.filter { seen.insert($0.shop.id).inserted }.prefix(count).map { $0 }
    }

    // MARK: - Conversational refinement

    @Test("A refinement reworks the deck in place, preserving the kit")
    @MainActor
    func refineReworksDeckInPlace() async {
        // ScriptedRefiner emits a price-cheaper directive; the rule-based curate default sorts the
        // deck by ascending price, so the rework is visible and deterministic.
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(priceDirection: .cheaper))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let kept = try! #require(model.deck.first)
        model.accept(kept)                                  // one item in the kit

        await model.applyRefinement(text: "make it cheaper")

        let prices = model.deck.map(\.price)
        #expect(prices == prices.sorted(by: <))             // re-sorted ascending
        #expect(model.isInKit(kept))                        // kit preserved
        #expect(!model.deck.contains { $0.id == kept.id })  // kit item not re-dealt
        #expect(model.refinementTurns == ["make it cheaper"])
        #expect(model.canSaveRefinementToTaste)             // the offer is now available
    }

    @Test("An addQueries refinement searches and merges new items, deduped")
    @MainActor
    func refineAddQueriesMergesNewItems() async {
        let base = Self.fakeProduct("base")
        let extra = Self.fakeProduct("extra")
        let fake = FakeUCP(byQuery: ["base": [base], "rain pants": [extra, base]]) // base overlaps → dedupe
        let model = AppModel(
            ucp: fake, curator: RuleBasedCurator(),
            refiner: ScriptedRefiner(.init(addQueries: ["rain pants"]))
        )
        let task = Self.fakeTask(queries: ["base"])
        model.enterPlan(with: task)      // sets selectedTask without a background load (avoids a race)
        await model.loadCandidates(for: task)
        #expect(model.candidates.map(\.id) == ["base"])

        await model.applyRefinement(text: "add rain pants")

        #expect(Set(model.candidates.map(\.id)) == ["base", "extra"]) // merged, deduped
    }

    @Test("Reset restores the originally dealt deck and clears the conversation")
    @MainActor
    func resetRestoresBaseDeck() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(removeHints: ["down"]))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let before = model.deck.map(\.id)

        await model.applyRefinement(text: "no down")
        model.resetRefinements()

        #expect(model.deck.map(\.id) == before)             // back to the original order
        #expect(model.refinementTurns.isEmpty)
        #expect(!model.canSaveRefinementToTaste)
    }

    @Test("The synchronous refinement entry point commits a thread turn")
    @MainActor
    func refinementEntryPointCommitsTurn() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)
        model.refine("make it cheaper")
        for _ in 0..<100 where model.refinementTurns.isEmpty { await Task.yield() }
        #expect(model.refinementTurns == ["make it cheaper"])
    }

    @Test("Entering a new mission clears the refinement conversation (ephemeral)")
    @MainActor
    func enterPlanClearsRefinement() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            refiner: ScriptedRefiner(.init(emphasis: "warmer"))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "warmer")
        #expect(!model.refinementTurns.isEmpty)

        await model.runPlan(goal: "Set up my pour-over corner")   // new mission

        #expect(model.refinementTurns.isEmpty)
        #expect(model.refinementTier == nil)
        #expect(!model.canSaveRefinementToTaste)
    }

    @Test("Save to taste folds the refinement in via the extractor when a model is available")
    @MainActor
    func saveToTasteUsesExtractor() async {
        let store = InMemoryTasteStore(SeedData.defaultTasteProfile)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: store,
            tasteExtractor: StubExtractor(Self.splurge),     // a model "read" of the refinement
            refiner: ScriptedRefiner(.init(emphasis: "warmer"))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "warmer")

        await model.saveRefinementToTaste()

        #expect(model.tasteProfile == Self.splurge.normalized)
        #expect(store.loadProfile() == Self.splurge.normalized)  // persisted for future missions
        #expect(!model.canSaveRefinementToTaste)                 // offer consumed
    }

    @Test("Save to taste falls back to a deterministic fold when no model is available")
    @MainActor
    func saveToTasteDeterministicFold() async {
        let store = InMemoryTasteStore(Self.balanced)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: store,
            tasteExtractor: ManualTasteExtractor(),          // nil → deterministic floor
            refiner: ScriptedRefiner(.init(emphasis: "warmer tones", priceDirection: .cheaper))
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "warmer tones, cheaper")

        await model.saveRefinementToTaste()

        #expect(model.tasteProfile.budgetComfort < Self.balanced.budgetComfort) // cheaper nudged down
        #expect(model.tasteProfile.leanings.contains("warmer tones"))           // emphasis → leaning
        #expect(store.loadProfile() == model.tasteProfile)                      // persisted
    }

    private static let balanced = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.5, signatureLine: ""
    )

    // MARK: - Taste capture & onboarding

    @Test("First run (no saved profile) opens onboarding")
    @MainActor
    func firstRunOpensOnboarding() {
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore()   // empty → first run
        )
        #expect(model.route == .onboarding)
        // The seed profile is the editable starting point until they finish.
        #expect(model.tasteProfile == SeedData.defaultTasteProfile)
    }

    @Test("Completing onboarding persists the profile and routes into the app")
    @MainActor
    func completeOnboardingPersists() {
        let store = InMemoryTasteStore()
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        let built = TasteProfile(
            vibe: ["Bold"], leanings: ["Tech-forward"],
            budgetComfort: 0.9, signatureLine: "Give me the best."
        )

        model.completeOnboarding(with: built)

        #expect(model.route == .missions)
        #expect(model.tasteProfile == built)
        #expect(store.loadProfile() == built)            // survives relaunch
    }

    @Test("Skipping onboarding still persists a profile so it doesn't reappear")
    @MainActor
    func skipOnboardingPersistsSeed() {
        let store = InMemoryTasteStore()
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)

        model.skipOnboarding()

        #expect(model.route == .missions)
        #expect(store.loadProfile() == SeedData.defaultTasteProfile)
        // A fresh launch over the same store now sees a returning user.
        let relaunched = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        #expect(relaunched.route == .missions)
    }

    @Test("Editing taste persists it and re-curates the live deck (personalization is felt)")
    @MainActor
    func updateTasteRecuratesDeck() async {
        let store = InMemoryTasteStore(Self.thrifty)
        let model = AppModel(
            ucp: MockUCPClient(),
            curator: ProfileSortCurator(),
            tasteStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        // Thrifty profile → ProfileSortCurator deals the deck id-ascending.
        let before = model.deck.map(\.id)
        #expect(before == before.sorted())

        // Flip to splurge and re-curate the deck in place.
        model.updateTaste(Self.splurge)
        await Task.yield()
        while model.isRecurating { await Task.yield() }

        let after = model.deck.map(\.id)
        #expect(after == before.sorted(by: >))       // visibly re-ranked (now descending)
        #expect(Set(after) == Set(before))           // same set, nothing lost
        #expect(model.tasteProfile == Self.splurge)
        #expect(store.loadProfile() == Self.splurge) // and persisted
    }

    @Test("Editing taste with nothing loaded just persists (no deck to re-curate)")
    @MainActor
    func updateTasteWithoutDeckPersists() {
        let store = InMemoryTasteStore(SeedData.defaultTasteProfile)
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator(), tasteStore: store)
        #expect(model.candidates.isEmpty)

        model.updateTaste(Self.splurge)

        #expect(model.tasteProfile == Self.splurge)
        #expect(store.loadProfile() == Self.splurge)
        #expect(model.isRecurating == false)
    }

    private static let thrifty = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.1, signatureLine: ""
    )
    private static let splurge = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.9, signatureLine: ""
    )

    // MARK: - History

    /// Answers product questions until the kit question — the one carrying "End mission" — is the
    /// pending interaction. Bounded so a reducer regression fails the test instead of hanging it.
    @MainActor
    private static func advanceToKitQuestion(_ model: AppModel) throws -> MissionPendingInteraction {
        var turns = 0
        while model.activeThread?.pendingInteraction?.kind == .productDecision, turns < 50 {
            model.submitMissionOption("skip")
            turns += 1
        }
        let interaction = try #require(model.activeThread?.pendingInteraction)
        #expect(interaction.kind == .cartReview)
        return interaction
    }

    /// The regression this whole change exists for. `recordKitToHistory()` had exactly one caller —
    /// `openCart()` — so a kit that was assembled and then ended without ever tapping "Review cart"
    /// was written nowhere a screen reads: its thread phase is terminal, so Home drops it, and
    /// History is fed by `historyStore`, not `threadStore`. Nothing asserted this, which is why the
    /// path could exist at all.
    @Test("Ending a mission with a kept kit records it to History — without ever opening the cart")
    @MainActor
    func endingMissionWithKitWritesHistory() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        let kept = try #require(model.deck.first)
        model.accept(kept)

        let kitQuestion = try Self.advanceToKitQuestion(model)
        #expect(kitQuestion.options.map(\.id).contains("end"))
        #expect(model.kit.map(\.product.id) == [kept.id])
        #expect(store.loadEntries().isEmpty)              // the cart was never opened

        model.submitMissionOption("end")

        // The write is fire-and-forget behind the async recap, exactly as the cart path is.
        for _ in 0..<200 where store.loadEntries().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }

        let entry = try #require(store.loadEntries().first)
        #expect(entry.items.map(\.productID) == [kept.id])
        #expect(entry.title == SeedData.hike.title)
        #expect(!entry.recapTag.isEmpty)
        #expect(model.historyEntries.count == 1)
        // The mission really did end: terminal phase, gone from Home, and now reachable in History.
        #expect(model.activeThread?.phase == .completed)
        #expect(model.incompleteThreads.contains { $0.id == model.activeThreadID } == false)
    }

    /// The confirmation and the demotion both key off this one flag, and it costs no option slot —
    /// so the four-option interaction cap (whose violation silently rolls back the entire
    /// `mutateActiveThread` transaction) is untouched.
    @Test("Every option that ends the mission is marked destructive, and none of them costs a slot")
    @MainActor
    func terminalOptionsAreMarkedDestructive() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        let kitQuestion = try Self.advanceToKitQuestion(model)

        #expect(kitQuestion.options.count <= 4)
        let end = try #require(kitQuestion.options.first { $0.id == "end" })
        #expect(end.isDestructive)
        // …and nothing you do *inside* the mission is dressed as an exit.
        #expect(kitQuestion.options.filter(\.isDestructive).map(\.id) == ["end"])
        for id in ["review-cart", "find-more"] {
            #expect(kitQuestion.options.first { $0.id == id }?.isDestructive == false)
        }
    }

    @Test("Ending a mission that kept nothing still records nothing")
    @MainActor
    func endingEmptyMissionWritesNothing() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)

        _ = try Self.advanceToKitQuestion(model)          // skipped everything
        model.submitMissionOption("end")
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.kit.isEmpty)
        #expect(store.loadEntries().isEmpty)
        #expect(model.historyEntries.isEmpty)
    }

    @Test("Opening the cart and then ending the mission upserts one entry, not two")
    @MainActor
    func cartThenEndKeepsOneEntry() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        _ = try Self.advanceToKitQuestion(model)

        model.submitMissionOption("review-cart")           // the original save trigger
        for _ in 0..<200 where store.loadEntries().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let firstID = try #require(store.loadEntries().first).id

        _ = try Self.advanceToKitQuestion(model)
        model.submitMissionOption("end")                   // and now the new one
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.loadEntries().count == 1)
        #expect(store.loadEntries().first?.id == firstID)
    }

    @Test("Reaching the cart with a kit writes a snapshotted history entry (recap on the floor)")
    @MainActor
    func reachingCartWritesHistory() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))

        await model.recordCurrentKit()                 // the openCart write path

        #expect(model.historyEntries.count == 1)
        let entry = try #require(model.historyEntries.first)
        #expect(entry.items.count == 1)
        #expect(entry.title == SeedData.hike.title)
        #expect(!entry.recapTag.isEmpty)               // recap written (rule-based on CI)
        #expect(!entry.recapLine.isEmpty)
        #expect(!entry.handedOff)                       // not yet handed off
        #expect(store.loadEntries().count == 1)         // persisted to the store
    }

    @Test("An abandoned plan with nothing kept records no history")
    @MainActor
    func emptyKitWritesNothing() async {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)

        await model.recordCurrentKit()                 // no items kept

        #expect(model.historyEntries.isEmpty)
        #expect(store.loadEntries().isEmpty)
    }

    @Test("Re-reaching the cart in one session updates the same entry, not a duplicate")
    @MainActor
    func reReachingCartUpdatesSameEntry() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()
        let firstID = try #require(model.historyEntries.first).id

        model.accept(try #require(model.deck.first))   // keep one more, same session
        await model.recordCurrentKit()

        #expect(model.historyEntries.count == 1)       // upsert, not a new entry
        #expect(model.historyEntries.first?.id == firstID)
        #expect(model.historyEntries.first?.items.count == 2)
    }

    @Test("Building a kit for the same goal in a new session makes a second, distinct entry")
    @MainActor
    func newSessionMakesNewEntry() async throws {
        var clockValue = Date(timeIntervalSinceReferenceDate: 1_000)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            clock: { clockValue }
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        clockValue = clockValue.addingTimeInterval(60)  // a later, distinct session
        model.enterPlan(with: SeedData.hike)            // same goal, new session
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        #expect(model.historyEntries.count == 2)        // two distinct shopping sessions
    }

    @Test("Following a real checkout link flips this session's outcome flag (and persists it)")
    @MainActor
    func handoffFollowedFlipsOutcome() async throws {
        let store = InMemoryHistoryStore()
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()
        #expect(model.historyEntries.first?.handedOff == false)

        model.recordHandoffFollowed()

        #expect(model.historyEntries.first?.handedOff == true)
        #expect(store.loadEntries().first?.handedOff == true)
    }

    @Test("Delete removes one entry; clear empties the whole history")
    @MainActor
    func deleteAndClearHistory() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        for mission in [SeedData.hike, SeedData.coffee] {
            model.enterPlan(with: mission)
            await model.loadCandidates(for: mission)
            model.accept(try #require(model.deck.first))
            await model.recordCurrentKit()
        }
        #expect(model.historyEntries.count == 2)

        model.deleteHistoryEntry(try #require(model.historyEntries.first))
        #expect(model.historyEntries.count == 1)

        model.clearHistory()
        #expect(model.historyEntries.isEmpty)
    }

    @Test("Plan-this-again re-plans the goal into a fresh shopping thread and clears the detail state")
    @MainActor
    func planAgainReplansGoal() async {
        let seeded = SeedData.historyEntries(now: Date())
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: InMemoryHistoryStore(seeded)
        )
        let entry = model.historyEntries.first!
        model.openHistoryDetail(entry)
        model.beginReshop(entry)
        model.planAgain(entry)                          // clears overlay state synchronously

        #expect(model.reshopEntry == nil)
        #expect(model.selectedHistoryEntry == nil)

        // The substance of "plan again": routing the goal back through the planner yields a plan.
        await model.runPlan(goal: entry.goal)
        #expect(model.route == .missionThread)
        #expect(model.selectedTask != nil)
    }

    @Test("Aggregate history stats are exposed for the timeline header")
    @MainActor
    func historyStatsExposed() {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: InMemoryHistoryStore(SeedData.historyEntries(now: Date()))
        )
        #expect(model.historyStats.kitCount == 5)       // the five seeded missions
        #expect(model.historyStats.isMilestone)         // 5 is a milestone
        #expect(model.historyStats.itemCount > 0)
        #expect(model.historyStats.shopCount > 0)
    }

    @Test("Re-reaching the cart with an unchanged kit does not regenerate the recap (no jitter)")
    @MainActor
    func recapStableOnUnchangedReReach() async throws {
        let writer = CountingRecapWriter()                // a fresh tag/line every call
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            recapWriter: writer
        )
        model.enterPlan(with: SeedData.hike)
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()
        let firstLine = try #require(model.historyEntries.first).recapLine
        let callsAfterFirst = writer.calls

        await model.recordCurrentKit()                    // same kit, re-reach

        #expect(model.historyEntries.first?.recapLine == firstLine) // recap unchanged
        #expect(writer.calls == callsAfterFirst)                    // writer not called again
    }

    @Test("A saved entry keeps the user's original goal text, not the title-cased task title")
    @MainActor
    func savedGoalIsTheOriginalText() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        await model.runPlan(goal: "pack me for a rainy weekend hike")  // composer path
        await model.beginCuration()
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        let entry = try #require(model.historyEntries.first)
        #expect(entry.goal == "pack me for a rainy weekend hike")      // verbatim, for plan-again
        #expect(entry.title != entry.goal)                             // title is the cased derivation
    }

    // MARK: - Gift missions (shop for someone else)

    /// A recipient whose taste is *distinct* from the owner, so a gift mission's lens is observable.
    private static func giftRecipient() -> Recipient {
        Recipient(
            id: "mom", name: "Mom", relationship: "my mom",
            taste: Self.splurge,                       // ≠ the owner's default profile
            accentHex: 0x9A6A4F, createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    @Test("A gift mission curates through the recipient's taste, not the owner's")
    @MainActor
    func giftMissionUsesRecipientTaste() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: ProfileSortCurator(),   // order encodes which taste ran
            tasteStore: InMemoryTasteStore(Self.thrifty)           // owner = thrifty → id-ascending
        )
        let mom = Self.giftRecipient()                             // splurge → id-descending
        model.enterPlan(with: SeedData.hike, recipient: mom)
        #expect(model.activeRecipient?.id == "mom")
        #expect(model.activeTaste == Self.splurge)                 // the switch resolves to her taste

        await model.loadCandidates(for: SeedData.hike)
        let ids = model.deck.map(\.id)
        #expect(ids == ids.sorted(by: >))                          // ranked by *her* (splurge) taste
        #expect(model.tasteProfile == Self.thrifty)                // owner profile untouched
    }

    @Test("Selecting Yourself behaves exactly as today (no recipient, owner taste)")
    @MainActor
    func yourselfIsRegressionFree() async {
        let model = AppModel(
            ucp: MockUCPClient(), curator: ProfileSortCurator(),
            tasteStore: InMemoryTasteStore(Self.thrifty)
        )
        model.enterPlan(with: SeedData.hike)                       // no recipient
        #expect(model.activeRecipient == nil)
        #expect(model.activeTaste == Self.thrifty)
        #expect(model.activeRecipientRef == nil)
        await model.loadCandidates(for: SeedData.hike)
        let ids = model.deck.map(\.id)
        #expect(ids == ids.sorted())                               // owner (thrifty) order
    }

    @Test("A gift kit records the recipient on its history entry; an owner kit records none")
    @MainActor
    func giftKitTagsHistory() async throws {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.hike, recipient: Self.giftRecipient())
        await model.loadCandidates(for: SeedData.hike)
        model.accept(try #require(model.deck.first))
        await model.recordCurrentKit()

        let entry = try #require(model.historyEntries.first)
        #expect(entry.recipient?.id == "mom")
        #expect(entry.recipient?.name == "Mom")
        #expect(entry.recapLine.contains("a gift for Mom"))        // deterministic gift floor (CI)
    }

    @Test("Save-to-taste during a gift mission folds into the recipient; the owner is untouched")
    @MainActor
    func saveToTasteTargetsRecipient() async {
        let recipientStore = InMemoryRecipientStore([Self.giftRecipient()])
        let tasteStore = InMemoryTasteStore(Self.balanced)
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: tasteStore,
            tasteExtractor: ManualTasteExtractor(),                // nil → deterministic fold
            refiner: ScriptedRefiner(.init(emphasis: "ceramic", priceDirection: .cheaper)),
            recipientStore: recipientStore
        )
        let mom = try! #require(model.recipients.first)
        model.enterPlan(with: SeedData.hike, recipient: mom)
        await model.loadCandidates(for: SeedData.hike)
        await model.applyRefinement(text: "more ceramic, cheaper")

        #expect(model.saveToTasteLabel == "Make this part of Mom's taste")
        await model.saveRefinementToTaste()

        let saved = try! #require(recipientStore.loadRecipients().first { $0.id == "mom" })
        #expect(saved.taste.leanings.contains("ceramic"))          // folded into *her* profile…
        #expect(model.activeRecipient?.taste.leanings.contains("ceramic") == true) // …and the live lens
        #expect(tasteStore.loadProfile() == Self.balanced)         // owner profile untouched
    }

    @Test("People CRUD: add assigns id+accent, edit replaces, delete removes (and clears composer)")
    @MainActor
    func peopleRosterCRUD() {
        let model = AppModel(ucp: MockUCPClient(), curator: RuleBasedCurator())
        #expect(model.recipients.isEmpty)

        let dad = model.addRecipient(name: "Dad", relationship: "my dad", taste: Self.splurge)
        #expect(model.recipients.map(\.name) == ["Dad"])
        #expect(!dad.id.isEmpty)
        #expect(dad.accentHex == AppModel.recipientAccents[0])

        var edited = dad
        edited.name = "Papa"
        model.composerRecipient = dad
        model.updateRecipient(edited)
        #expect(model.recipients.first?.name == "Papa")
        #expect(model.composerRecipient?.name == "Papa")           // live selection follows the edit

        model.deleteRecipient(id: dad.id)
        #expect(model.recipients.isEmpty)
        #expect(model.composerRecipient == nil)                    // selection cleared on delete
    }

    @Test("Plan-this-again for a gift entry re-targets the same person when still in the roster")
    @MainActor
    func planAgainResolvesRecipient() async {
        let recipientStore = InMemoryRecipientStore([Self.giftRecipient()])
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            recipientStore: recipientStore
        )
        let mom = try! #require(model.recipients.first)
        model.enterPlan(with: SeedData.coffee, recipient: mom)
        await model.loadCandidates(for: SeedData.coffee)
        model.accept(model.deck.first!)
        await model.recordCurrentKit()
        let entry = try! #require(model.historyEntries.first)

        await model.runPlan(goal: entry.goal, for: model.recipients.first { $0.id == entry.recipient?.id })
        #expect(model.activeRecipient?.id == "mom")                // re-planned for Mom
    }

    @Test("The History recipient filter narrows the timeline and the stats header")
    @MainActor
    func historyFilterNarrows() {
        let momRef = RecipientRef(id: "mom", name: "Mom", accentHex: 0x9A6A4F)
        let store = InMemoryHistoryStore([
            Self.historyFixture(id: "gift", recipient: momRef),
            Self.historyFixture(id: "owned", recipient: nil),
        ])
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile),
            historyStore: store
        )
        #expect(model.historyFacets.map(\.id) == ["all", "yourself", "person-mom"])
        #expect(model.filteredHistoryEntries.count == 2)

        model.historyRecipientFilter = .person("mom")
        #expect(model.filteredHistoryEntries.map(\.id) == ["gift"])
        #expect(model.historyStats.kitCount == 1)                  // stats follow the filter
    }

    private static func historyFixture(id: String, recipient: RecipientRef?) -> HistoryEntry {
        HistoryEntry(
            id: id, goal: "g", title: "T", subtitle: "s", plan: ["a"], searchQueries: ["a"],
            curatorNote: "", accentHex: 0, recapTag: "Tag", recapLine: "Line",
            items: [HistoryItem(productID: "p", name: "Item", shop: Shop(id: "s", name: "Shop"),
                                price: 10, variantTitle: "Standard")],
            recipient: recipient, handedOff: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    // MARK: - Fixtures

    private static func fakeProduct(_ id: String) -> Product {
        Product(
            id: id, name: id, shop: Shop(id: "s", name: "Shop"), price: 10,
            rating: 0, reviews: 0, rationale: "", symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: "Standard", price: 10)]
        )
    }

    private static func fakeTask(queries: [String]) -> ShoppingTask {
        ShoppingTask(
            id: "fake", title: "Fake", subtitle: "", plan: [], curatorNote: "",
            accentHex: 0, candidateIDs: [], searchQueries: queries
        )
    }
}

/// A test curator whose order depends on the profile, so a taste change produces a *visible*
/// re-rank: low budget comfort deals id-ascending, high deals id-descending. (Deterministic,
/// no model — the whole point is to prove `updateTaste` re-curates against the new profile.)
private struct ProfileSortCurator: CuratorEngine {
    func plan(for task: ShoppingTask) async -> [String] { task.plan }

    func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        profile.budgetComfort < 0.5
            ? products.sorted { $0.id < $1.id }
            : products.sorted { $0.id > $1.id }
    }

    func rationale(for product: Product, profile: TasteProfile) -> String { product.rationale }

    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        CuratedDeck(products: await rank(products, for: profile), tier: .onDevice)
    }
}

/// A curator that stalls before ranking, standing in for a slow/hung on-device model turn so the
/// settle watchdog + hard deadline (#57) can be exercised deterministically. It delegates voice and
/// ranking to ``RuleBasedCurator`` after the delay, and reports the on-device tier (so a *successful*
/// slow curation is distinguishable from the deterministic fallback).
private struct DelayingCurator: CuratorEngine {
    let delay: Duration
    private let inner = RuleBasedCurator()

    func plan(for task: ShoppingTask) async -> [String] { await inner.plan(for: task) }

    func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        try? await Task.sleep(for: delay)
        return await inner.rank(products, for: profile)
    }

    func rationale(for product: Product, profile: TasteProfile) -> String {
        inner.rationale(for: product, profile: profile)
    }

    func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        let ranked = await rank(products, for: profile)   // the delay lives here
        let voiced = ranked.map { $0.withRationale(inner.rationale(for: $0, profile: profile, recipient: recipient, mission: mission)) }
        return CuratedDeck(products: voiced, tier: .onDevice)
    }
}

/// A deterministic ``RefinementInterpreter`` for tests: it ignores the text and always returns a
/// scripted directive on the on-device tier, so `AppModel`'s rework path can be exercised without
/// a model (which is unavailable on the sim/CI).
private struct ScriptedRefiner: RefinementInterpreter {
    let directive: RefinementDirective
    init(_ directive: RefinementDirective) { self.directive = directive }

    func interpret(
        _ refinement: String,
        conversation: [String],
        mission: ShoppingTask,
        profile: TasteProfile
    ) async -> InterpretedRefinement {
        InterpretedRefinement(directive: directive, tier: .onDevice)
    }
}

/// A ``RecapWriter`` that returns a *distinct* tag/line on every call, so a test can prove the
/// app reuses a stored recap (rather than regenerating it) when a kit is unchanged on cart re-reach.
@MainActor
private final class CountingRecapWriter: RecapWriter {
    private(set) var calls = 0
    nonisolated func writeRecap(
        goal: String, plan: [String], items: [RecapFact], profile: TasteProfile, recipient: RecipientRef?
    ) async -> WrittenRecap {
        await MainActor.run {
            calls += 1
            return WrittenRecap(tag: "Tag \(calls)", line: "Line \(calls)", tier: .onDevice)
        }
    }
}

/// A ``TasteExtractor`` test double that returns a fixed profile (standing in for a real model
/// "read" of the refinement text), so the save-to-taste extractor path is testable on CI.
private struct StubExtractor: TasteExtractor {
    let result: TasteProfile
    init(_ result: TasteProfile) { self.result = result }
    func extract(from text: String, base: TasteProfile) async -> TasteProfile? { result }
}

/// An in-test ``UCPClient`` that maps queries to canned results and can fail selectively.
private struct FakeUCP: UCPClient {
    let byQuery: [String: [Product]]
    var failing: Set<String> = []
    var failAll = false

    func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product] {
        if failAll || failing.contains(query) {
            throw UCPError.productNotFound(query)
        }
        return byQuery[query] ?? []
    }

    func product(id: Product.ID) async throws -> Product {
        throw UCPError.productNotFound(id)
    }

    func assembleCart(_ items: [KitItem]) async throws -> Cart { Cart(items: items) }

    func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        throw UCPError.emptyShopHandoff(shop.id)
    }
}

private actor CheckoutRecordingUCP: UCPClient {
    private var recorded: [(shop: Shop.ID, key: String)] = []
    private var recordedItems: [Shop.ID: [String]] = [:]
    private let failFirstFor: Shop.ID?
    private let status: CheckoutStatus
    private let unsupported: Bool

    init(
        failFirstFor: Shop.ID? = nil,
        status: CheckoutStatus = .requiresEscalation,
        unsupported: Bool = false
    ) {
        self.failFirstFor = failFirstFor
        self.status = status
        self.unsupported = unsupported
    }

    func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product] { [] }
    func product(id: Product.ID) async throws -> Product { throw UCPError.productNotFound(id) }
    func assembleCart(_ items: [KitItem]) async throws -> Cart { Cart(items: items) }
    func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        URL(string: "https://merchant.example/\(cart.items.first?.id ?? "cart")")!
    }

    func createCheckout(
        for shop: Shop, items: [KitItem], idempotencyKey: String
    ) async throws -> CheckoutSession {
        recorded.append((shop.id, idempotencyKey))
        recordedItems[shop.id] = items.map(\.id)
        if unsupported { throw UCPError.checkoutUnsupported(shop.id) }
        if shop.id == failFirstFor, recorded.filter({ $0.shop == shop.id }).count == 1 {
            throw CheckoutTestError.transient
        }
        let amount = items.reduce(0) { $0 + NSDecimalNumber(decimal: $1.variant.price * 100).intValue }
        return CheckoutSession(
            id: "checkout-\(shop.id)", shop: shop, status: status,
            currency: "USD", lineItems: [], totals: [CheckoutTotal(type: "total", amount: amount)],
            continueURL: URL(string: "https://checkout.example/\(shop.id)")
        )
    }

    func callCount() -> Int { recorded.count }
    func calls(for shopID: Shop.ID) -> [String] {
        recorded.filter { $0.shop == shopID }.map(\.key)
    }
    func itemIDs(for shopID: Shop.ID) -> [String] { recordedItems[shopID] ?? [] }

    private enum CheckoutTestError: Error { case transient }
}

/// A deterministic ``TasteExtractor`` double: stamps a "GoalSeeded" marker into the vibe so a test
/// can prove the goal-first onboarding path actually threads the goal through the extractor seam.
private struct MarkerTasteExtractor: TasteExtractor {
    func extract(from text: String, base: TasteProfile) async -> TasteProfile? {
        var seeded = base
        seeded.vibe.append("GoalSeeded")
        return seeded
    }
}

// MARK: - App Entities: onscreen deck control (#41)

/// The App Intents plumbing that exposes the swipe deck to Siri. Live Siri needs a device, but the
/// entity mapping, the ``ProductEntityQuery`` resolution against ``AppModel``, and each intent's
/// `perform()` are all exercisable here. `@Dependency` can't be resolved via
/// `AppDependencyManager` outside the real perform flow (it traps), but the framework lets us set
/// it manually — so each test assigns `.model` before running, exactly as documented.
@MainActor
struct DeckAppIntentTests {

    /// A real mock-backed deck so `deckProducts` / `sessionProduct(id:)` resolve.
    private func loadedModel() async -> AppModel {
        let model = AppModel(
            ucp: MockUCPClient(), curator: RuleBasedCurator(),
            tasteStore: InMemoryTasteStore(SeedData.defaultTasteProfile)
        )
        model.enterPlan(with: SeedData.coffee)
        await model.loadCandidates(for: SeedData.coffee)
        return model
    }

    @Test("ProductEntity carries the product's display fields")
    func entityMapsFields() {
        let product = SeedData.coffeeProducts[0]
        let entity = ProductEntity(product)
        #expect(entity.productID == product.id)
        #expect(entity.name == product.name)
        #expect(entity.shopName == product.shop.name)
        #expect(entity.rationale == product.rationale)
        #expect(entity.symbol == product.symbol)
        #expect(!entity.priceText.isEmpty)
    }

    @Test("The query suggests the visible deck and resolves ids (stale ids drop out)")
    func queryResolvesDeck() async throws {
        let model = await loadedModel()
        var query = ProductEntityQuery()
        query.model = model   // manual dependency injection (see suite note)

        let suggested = try await query.suggestedEntities()
        #expect(suggested.count == model.deckProducts.count)
        #expect(!suggested.isEmpty)

        let firstID = try #require(suggested.first).id
        let resolved = try await query.entities(for: [firstID, "not-a-real-id"])
        #expect(resolved.map(\.id) == [firstID])   // the bogus id is dropped, not faked
    }

    @Test("AddToKit adds the resolved product through the same path as a swipe")
    func addToKitAdds() async throws {
        let model = await loadedModel()
        let target = try #require(model.deckProducts.first)
        #expect(!model.isInKit(target))

        var intent = AddToKitIntent()
        intent.model = model
        intent.product = ProductEntity(target, threadID: model.activeThreadID, interaction: model.activeThread?.pendingInteraction)
        _ = try await intent.perform()

        #expect(model.isInKit(target))                 // kit mutated via AppModel.accept
        #expect(!model.deckProducts.contains { $0.id == target.id })  // advanced off the deck
    }

    @Test("Skip advances past the product without kitting it")
    func skipAdvances() async throws {
        let model = await loadedModel()
        let target = try #require(model.deckProducts.first)

        var intent = SkipProductIntent()
        intent.model = model
        intent.product = ProductEntity(target, threadID: model.activeThreadID, interaction: model.activeThread?.pendingInteraction)
        _ = try await intent.perform()

        #expect(!model.isInKit(target))
        #expect(!model.deckProducts.contains { $0.id == target.id })
    }

    @Test("A stale product id fails honestly instead of mutating nothing")
    func staleIdThrows() async throws {
        let model = await loadedModel()
        let before = model.kit.count

        var intent = AddToKitIntent()
        intent.model = model
        intent.product = ProductEntity(SeedData.hikeProducts[0])   // not in the coffee deck
        await #expect(throws: DeckIntentError.self) {
            _ = try await intent.perform()
        }
        #expect(model.kit.count == before)
    }

    @Test("ExplainPick answers from the entity's own rationale (even off-deck)")
    func explainPickSucceeds() async throws {
        var intent = ExplainPickIntent()
        intent.product = ProductEntity(SeedData.coffeeProducts[0])
        _ = try await intent.perform()   // returns dialog + snippet without throwing
    }
}
