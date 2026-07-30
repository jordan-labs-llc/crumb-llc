import Testing
import Foundation
import SwiftData
@testable import CrumbKit

@Suite("MissionThread domain and persistence")
struct MissionThreadTests {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let taste = TasteProfile(
        vibe: ["calm"], leanings: ["durable"], budgetComfort: 0.4,
        signatureLine: "quietly useful"
    )

    func planningThread(id: String = UUID().uuidString, at date: Date = Self.now) -> MissionThread {
        MissionThread(id: id, goal: "Pack me for a rainy hike", taste: Self.taste, now: date)
    }

    func deckThread(id: String = UUID().uuidString, at date: Date = Self.now) -> MissionThread {
        var thread = planningThread(id: id, at: date)
        thread.task = SeedData.hike
        thread.plan = zip(SeedData.hike.plan, SeedData.hike.searchQueries).enumerated().map {
            MissionPlanPart(id: "part-\($0.offset)", label: $0.element.0, query: $0.element.1)
        }
        thread.candidates = Array(SeedData.hikeProducts.prefix(3))
        thread.baseCandidates = thread.candidates
        thread.remainingDeckIDs = thread.candidates.map(\.id)
        thread.phase = .deckReady
        thread.advanceRevision(at: date.addingTimeInterval(1))
        return thread
    }

    @Test("Initializer mints unique durable identities and starts before planning")
    func initializer() {
        let a = planningThread()
        let b = planningThread()
        #expect(a.id != b.id)
        #expect(a.phase == .planning)
        #expect(a.originalGoal == a.goal)
        #expect(a.revision == 0)
        #expect(a.task == nil)
        #expect(a.timeline.isEmpty)
    }

    @Test("V2 codec round-trips the full authoritative snapshot")
    func codecRoundTrip() throws {
        let recipient = Recipient(
            id: "mom", name: "Mom", relationship: "mother", taste: Self.taste,
            accentHex: 0x1C4B43, createdAt: Self.now
        )
        var thread = deckThread(id: "thread-1")
        thread.recipient = recipient
        thread.tasteSnapshot = recipient.taste
        let added = thread.candidates[0]
        thread.kit = [KitItem(product: added)]
        thread.remainingDeckIDs.removeAll { $0 == added.id }
        thread.decisions = [MissionProductDecision(
            id: "op-add", kind: .added, productID: added.id,
            variantID: added.defaultVariant.id, createdAt: Self.now
        )]
        thread.refinementTurns = ["make it cheaper"]
        thread.refinementDirectives = [RefinementDirective(
            emphasis: "lighter", priceDirection: .cheaper
        )]
        thread.candidateParts = [added.id: "Rain jacket"]
        thread.historyEntryID = "history-1"
        thread.appendEvent(
            kind: .userMessage, text: "make it cheaper", createdAt: Self.now,
            operationID: "refine-1"
        )
        thread.advanceRevision(at: Self.now.addingTimeInterval(2))

        let data = try MissionThreadCodec.encode(thread)
        let decoded = try MissionThreadCodec.decode(data)
        #expect(decoded == thread)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == MissionThreadCodec.currentVersion)
    }

    @Test("Codec rejects an unsupported document version before decoding a domain shape")
    func unsupportedVersion() {
        let data = Data("{\"schemaVersion\":99}".utf8)
        #expect(throws: MissionThreadCodecError.unsupportedVersion(99)) {
            try MissionThreadCodec.decode(data)
        }
    }

    @Test("Checked-in frozen V1 fixture decodes independently of the current encoder")
    func checkedInV1Fixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mission_thread_v1.json")
        let thread = try MissionThreadCodec.decode(Data(contentsOf: url))
        #expect(thread.id == "fixture-thread-v1")
        #expect(thread.goal == "Find a calm desk lamp")
        #expect(thread.phase == .planning)
        #expect(thread.tasteSnapshot.leanings == ["warm light"])
        #expect(thread.interactionGeneration == 0)
        #expect(thread.pendingInteraction == nil)
        #expect(thread.blockingRecovery == nil)
    }

    @Test("Checked-in V2 fixture restores a pending clarification without inference")
    func checkedInV2Fixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mission_thread_v2_interaction.json")
        let thread = try MissionThreadCodec.decode(Data(contentsOf: url))
        #expect(thread.id == "fixture-thread-v2")
        #expect(thread.pendingInteraction?.id == "fixture-question")
        #expect(thread.pendingInteraction?.options.map(\.id) == ["recipient-self", "recipient-other"])
        guard case .clarification(let contextID) = thread.pendingInteraction?.resolver else {
            Issue.record("Expected typed clarification resolver")
            return
        }
        #expect(contextID == "gift-recipient")
    }

    @Test("V1 migration never invents a write-capable question in any phase")
    func v1PhaseMigration() throws {
        var base = deckThread(id: "phase-fixture")
        let phases: [MissionThreadPhase] = [.planning, .planReady, .gathering, .deckReady, .failed, .declined, .completed, .abandoned]
        for phase in phases {
            base.phase = phase
            base.pendingOperation = nil
            base.retry = phase == .failed
                ? MissionRetryDescriptor(kind: .planning, input: base.goal, returnPhase: .planning)
                : nil
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(MissionThreadDocumentV1(thread: base))
            let migrated = try MissionThreadCodec.decode(data)
            #expect(migrated.phase == phase)
            #expect(migrated.interactionGeneration == 0)
            #expect(migrated.pendingInteraction == nil)
            #expect(migrated.timeline.allSatisfy { $0.blocks.isEmpty })
        }
    }

    @Test("V2 preserves the unanswered question, typed resolver, and frozen product facts")
    func interactionRoundTrip() throws {
        var thread = deckThread(id: "interaction-thread")
        let product = try #require(thread.remainingDeck.first)
        let prompt = MissionThreadEvent(
            id: "prompt-product", sequence: thread.nextTimelineSequence,
            kind: .assistantMessage, text: "Would you add this jacket?", createdAt: Self.now,
            productID: product.id,
            blocks: [.product(MissionProductSnapshot(product: product, variant: product.defaultVariant))]
        )
        thread.timeline.append(prompt)
        let subjectRevision = thread.revision
        let pending = try thread.installInteraction(
            promptEventID: prompt.id,
            subjectRevision: subjectRevision,
            kind: .productDecision,
            question: "Would you add this jacket?",
            options: [
                MissionInteractionOption(id: "add", label: "Add"),
                MissionInteractionOption(id: "skip", label: "Skip"),
                MissionInteractionOption(id: "another", label: "Show another"),
            ],
            allowsFreeText: true,
            resolver: .product(productID: product.id, variantID: product.defaultVariant.id),
            createdAt: Self.now,
            id: "interaction-1"
        )
        thread.advanceRevision(at: Self.now.addingTimeInterval(2))

        let decoded = try MissionThreadCodec.decode(MissionThreadCodec.encode(thread))
        #expect(decoded == thread)
        #expect(decoded.pendingInteraction == pending)
        guard case .product(let snapshot) = decoded.timeline.last?.blocks.first else {
            Issue.record("Expected a frozen product snapshot")
            return
        }
        #expect(snapshot.productID == product.id)
        #expect(snapshot.presentedPrice == product.defaultVariant.price)
        #expect(snapshot.merchant == product.shop.name)
    }

    @Test("Submission validation uses stable IDs and rejects stale or ambiguous input")
    func submissionValidation() throws {
        var thread = deckThread(id: "submit-thread")
        let product = try #require(thread.remainingDeck.first)
        thread.timeline.append(MissionThreadEvent(
            id: "prompt", sequence: thread.nextTimelineSequence,
            kind: .assistantMessage, text: "Add it?", createdAt: Self.now,
            blocks: [.product(MissionProductSnapshot(product: product, variant: product.defaultVariant))]
        ))
        let pending = try thread.installInteraction(
            promptEventID: "prompt", subjectRevision: thread.revision,
            kind: .productDecision, question: "Add it?",
            options: [MissionInteractionOption(id: "add-product", label: "Add")],
            selectionMode: .confirmation, allowsFreeText: true,
            resolver: .product(productID: product.id, variantID: product.defaultVariant.id),
            createdAt: Self.now
        )
        let valid = MissionInteractionSubmission(
            threadID: thread.id, interactionID: pending.id,
            interactionGeneration: pending.interactionGeneration,
            subjectRevision: pending.subjectRevision, idempotencyID: "answer-1",
            answer: .option(id: "add-product")
        )
        #expect(try thread.validate(valid) == pending)

        var stale = valid
        stale = MissionInteractionSubmission(
            threadID: stale.threadID, interactionID: stale.interactionID,
            interactionGeneration: stale.interactionGeneration,
            subjectRevision: stale.subjectRevision + 1,
            idempotencyID: stale.idempotencyID, answer: stale.answer
        )
        #expect(throws: MissionInteractionSubmissionError.staleSubject(
            expected: pending.subjectRevision, received: pending.subjectRevision + 1
        )) { try thread.validate(stale) }

        let ambiguous = MissionInteractionSubmission(
            threadID: thread.id, interactionID: pending.id,
            interactionGeneration: pending.interactionGeneration,
            subjectRevision: pending.subjectRevision,
            answer: .option(id: "Add") // display label is not a semantic option ID
        )
        #expect(throws: MissionInteractionSubmissionError.unknownOption("Add")) {
            try thread.validate(ambiguous)
        }

        var replayed = thread
        replayed.timeline.append(MissionThreadEvent(
            sequence: replayed.nextTimelineSequence, kind: .notice, text: "Applied",
            createdAt: Self.now, operationID: valid.idempotencyID
        ))
        #expect(throws: MissionInteractionSubmissionError.reusedIdempotencyID(valid.idempotencyID)) {
            try replayed.validate(valid)
        }

        try thread.resolveInteraction(valid)
        #expect(thread.pendingInteraction == nil)
        #expect(throws: MissionInteractionSubmissionError.noPendingInteraction) {
            try thread.validate(valid)
        }
    }

    @Test("Interaction validation rejects corrupt generations, option IDs, prompts, and variants")
    func interactionCorruption() throws {
        let clean = deckThread(id: "corrupt-interaction")
        let product = try #require(clean.remainingDeck.first)

        func invalidThread(
            promptID: String = "prompt", generation: Int = 1,
            options: [MissionInteractionOption] = [MissionInteractionOption(id: "add", label: "Add")],
            variantID: String? = nil
        ) -> MissionThread {
            var thread = clean
            thread.timeline.append(MissionThreadEvent(
                id: "prompt", sequence: thread.nextTimelineSequence,
                kind: .assistantMessage, text: "Choose", createdAt: Self.now,
                blocks: [.product(MissionProductSnapshot(
                    product: product,
                    variant: variantID == "hallucinated"
                        ? Variant(id: "hallucinated", title: "Unknown", price: product.price)
                        : (variantID.flatMap { id in product.variants.first { $0.id == id } })
                ))]
            ))
            thread.interactionGeneration = 1
            thread.pendingInteraction = MissionPendingInteraction(
                id: "pending", promptEventID: promptID,
                interactionGeneration: generation, subjectRevision: thread.revision,
                kind: .productDecision, question: "Choose", options: options,
                selectionMode: .singleChoice, allowsFreeText: false,
                resolver: .product(productID: product.id, variantID: variantID),
                createdAt: Self.now
            )
            return thread
        }

        #expect(throws: MissionThreadValidationError.invalidInteraction("generation does not match the active epoch")) {
            var thread = invalidThread(generation: 2); try thread.validateAndNormalize()
        }
        #expect(throws: MissionThreadValidationError.unresolvedInteractionPrompt("missing")) {
            var thread = invalidThread(promptID: "missing"); try thread.validateAndNormalize()
        }
        #expect(throws: MissionThreadValidationError.invalidInteraction("option IDs and labels must be nonblank and unique")) {
            var thread = invalidThread(options: [
                MissionInteractionOption(id: "same", label: "One"),
                MissionInteractionOption(id: "same", label: "Two"),
            ]); try thread.validateAndNormalize()
        }
        #expect(throws: MissionThreadValidationError.unresolvedInteractionVariant(
            productID: product.id, variantID: "hallucinated"
        )) {
            var thread = invalidThread(variantID: "hallucinated"); try thread.validateAndNormalize()
        }
    }

    @Test("Undurable questions block answers and recovery cannot exist without a question")
    func blockingRecovery() throws {
        var thread = deckThread(id: "recovery-thread")
        let product = try #require(thread.remainingDeck.first)
        thread.timeline.append(MissionThreadEvent(
            id: "prompt", sequence: thread.nextTimelineSequence,
            kind: .assistantMessage, text: "Add?", createdAt: Self.now,
            blocks: [.product(MissionProductSnapshot(product: product, variant: product.defaultVariant))]
        ))
        let pending = try thread.installInteraction(
            promptEventID: "prompt", subjectRevision: thread.revision,
            kind: .productDecision, question: "Add?",
            options: [MissionInteractionOption(id: "add", label: "Add")],
            selectionMode: .confirmation, allowsFreeText: false,
            resolver: .product(productID: product.id, variantID: product.defaultVariant.id),
            createdAt: Self.now
        )
        thread.blockingRecovery = .savePendingInteraction(failedRevision: thread.revision)
        let answer = MissionInteractionSubmission(
            threadID: thread.id, interactionID: pending.id,
            interactionGeneration: pending.interactionGeneration,
            subjectRevision: pending.subjectRevision, answer: .option(id: "add")
        )
        #expect(throws: MissionInteractionSubmissionError.blockedByRecovery) {
            try thread.validate(answer)
        }
        thread.pendingInteraction = nil
        #expect(throws: MissionThreadValidationError.invalidInteraction("pending-interaction recovery has no question")) {
            try thread.validateAndNormalize()
        }
    }

    @Test("Invalid replacement preserves the current interaction and generation")
    func invalidReplacementPreservesQuestion() throws {
        var thread = deckThread()
        let product = try #require(thread.remainingDeck.first)
        thread.timeline.append(MissionThreadEvent(
            id: "good-prompt", sequence: thread.nextTimelineSequence, kind: .assistantMessage,
            text: "Add?", createdAt: Self.now,
            blocks: [.product(MissionProductSnapshot(product: product, variant: product.defaultVariant))]
        ))
        let prior = try thread.installInteraction(
            promptEventID: "good-prompt", subjectRevision: thread.revision,
            kind: .productDecision, question: "Add?",
            options: [MissionInteractionOption(id: "add", label: "Add")],
            allowsFreeText: false,
            resolver: .product(productID: product.id, variantID: product.defaultVariant.id),
            createdAt: Self.now
        )
        #expect(throws: MissionThreadValidationError.unresolvedInteractionPrompt("missing")) {
            try thread.installInteraction(
                promptEventID: "missing", subjectRevision: thread.revision,
                kind: .clarification, question: "Bad", options: [], allowsFreeText: true,
                resolver: .clarification(contextID: "bad"), createdAt: Self.now
            )
        }
        #expect(thread.pendingInteraction == prior)
        #expect(thread.interactionGeneration == prior.interactionGeneration)
    }

    @Test("Negative thread and interaction revisions are corrupt, not normalized")
    func negativeRevisionsQuarantine() {
        var negativeRevision = planningThread()
        negativeRevision.revision = -1
        #expect(throws: MissionThreadValidationError.invalidRevision(-1)) {
            try negativeRevision.validateAndNormalize()
        }
        var negativeGeneration = planningThread()
        negativeGeneration.interactionGeneration = -1
        #expect(throws: MissionThreadValidationError.invalidInteractionGeneration(-1)) {
            try negativeGeneration.validateAndNormalize()
        }
    }

    @Test("Pending frozen subjects must exactly match authoritative plan, product, and kit")
    func pendingSnapshotMismatch() throws {
        var productThread = deckThread()
        let product = try #require(productThread.remainingDeck.first)
        let wrongPrice = MissionProductSnapshot(
            productID: product.id, variantID: product.defaultVariant.id, title: product.name,
            merchant: product.shop.name, presentedPrice: 0, variantTitle: product.defaultVariant.title,
            rationale: product.rationale
        )
        productThread.timeline.append(MissionThreadEvent(
            id: "price-prompt", sequence: productThread.nextTimelineSequence,
            kind: .assistantMessage, text: "Add?", createdAt: Self.now, blocks: [.product(wrongPrice)]
        ))
        #expect(throws: MissionThreadValidationError.unresolvedInteractionSnapshot(product.id)) {
            try productThread.installInteraction(
                promptEventID: "price-prompt", subjectRevision: productThread.revision,
                kind: .productDecision, question: "Add?",
                options: [MissionInteractionOption(id: "add", label: "Add")], allowsFreeText: false,
                resolver: .product(productID: product.id, variantID: product.defaultVariant.id), createdAt: Self.now
            )
        }

        var planThread = deckThread()
        planThread.phase = .planReady
        planThread.timeline.append(MissionThreadEvent(
            id: "plan-prompt", sequence: planThread.nextTimelineSequence,
            kind: .assistantMessage, text: "Shop?", createdAt: Self.now,
            blocks: [.plan(MissionPlanSnapshot(id: "bad-plan", revision: planThread.revision,
                                               title: planThread.task!.title, parts: [MissionPlanPart(label: "Wrong", query: "wrong")]))]
        ))
        #expect(throws: MissionThreadValidationError.invalidInteraction("plan resolver does not match a frozen plan")) {
            try planThread.installInteraction(
                promptEventID: "plan-prompt", subjectRevision: planThread.revision,
                kind: .planApproval, question: "Shop?",
                options: [MissionInteractionOption(id: "shop", label: "Shop")], allowsFreeText: false,
                resolver: .plan(planRevision: planThread.revision), createdAt: Self.now
            )
        }
    }

    @Test("Validation normalizes identical duplicates but rejects unresolved deck IDs")
    func invariants() throws {
        var thread = deckThread()
        thread.candidates.append(thread.candidates[0])
        thread.remainingDeckIDs.append(thread.remainingDeckIDs[0])
        try thread.validateAndNormalize()
        #expect(Set(thread.candidates.map(\.id)).count == thread.candidates.count)
        #expect(Set(thread.remainingDeckIDs).count == thread.remainingDeckIDs.count)

        thread.remainingDeckIDs.append("missing")
        #expect(throws: MissionThreadValidationError.unresolvedDeckProduct("missing")) {
            try thread.validateAndNormalize()
        }
    }

    @Test("Validation rejects a kit variant that does not belong to its product")
    func invalidVariant() {
        var thread = deckThread()
        let product = thread.candidates[0]
        thread.kit = [KitItem(
            product: product,
            variant: Variant(id: "foreign", title: "Foreign", price: 1)
        )]
        #expect(throws: MissionThreadValidationError.invalidKitVariant(
            productID: product.id, variantID: "foreign"
        )) {
            try thread.validateAndNormalize()
        }
    }

    @Test("Interrupted gather recovers exactly once without replaying search")
    func interruptionRecovery() throws {
        var thread = deckThread()
        thread.phase = .gathering
        thread.pendingOperation = MissionPendingOperation(
            id: "gather-1",
            retry: MissionRetryDescriptor(
                kind: .gathering, taskRevision: thread.revision, returnPhase: .planReady
            ),
            startedAt: Self.now
        )
        let before = thread.revision
        try thread.recoverAfterInterruption(at: Self.now.addingTimeInterval(5))
        #expect(thread.phase == .deckReady) // partial products remain actionable
        #expect(thread.pendingOperation == nil)
        #expect(thread.retry?.kind == .gathering)
        #expect(thread.timeline.count { $0.kind == .interrupted } == 1)
        #expect(thread.revision == before + 1)

        try thread.recoverAfterInterruption(at: Self.now.addingTimeInterval(6))
        #expect(thread.timeline.count { $0.kind == .interrupted } == 1)
        #expect(thread.revision == before + 1)
    }

    @Test("In-memory store is revision ordered and equal revisions are idempotent only")
    @MainActor
    func revisionOrdering() throws {
        let store = InMemoryMissionThreadStore()
        var current = planningThread(id: "thread")
        try store.save(current)
        try store.save(current) // byte/value-identical idempotent save

        current.advanceRevision(at: Self.now.addingTimeInterval(1))
        try store.save(current)

        var stale = current
        stale.revision = 0
        #expect(throws: MissionThreadStoreError.staleRevision(stored: 1, incoming: 0)) {
            try store.save(stale)
        }

        var conflict = current
        conflict.goal = "different state, same revision"
        #expect(throws: MissionThreadStoreError.conflictingRevision(1)) {
            try store.save(conflict)
        }
        #expect(store.load().threads.first?.goal == current.goal)
    }

    @Test("SwiftData store round-trips and quarantines a corrupt row")
    @MainActor
    func swiftDataRoundTripAndQuarantine() throws {
        let container = try ModelContainer(
            for: MissionThreadRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = SwiftDataMissionThreadStore(container: container, clock: { Self.now })
        var valid = deckThread(id: "valid")
        valid.appendEvent(kind: .notice, text: "ready", createdAt: Self.now)
        valid.advanceRevision(at: Self.now.addingTimeInterval(2))
        try store.save(valid)

        let corrupt = planningThread(id: "corrupt")
        let row = MissionThreadRecord(corrupt, payloadData: Data("not-json".utf8))
        container.mainContext.insert(row)
        try container.mainContext.save()

        let loaded = store.load()
        #expect(loaded.threads == [valid])
        #expect(loaded.failures.map(\.id) == ["corrupt"])

        try store.delete(id: loaded.failures[0].id)
        #expect(store.load().failures.isEmpty)
    }

    @Test("SwiftData load rewrites a valid V1 row as V2 without advancing its revision")
    @MainActor
    func swiftDataMigratesV1() throws {
        let container = try ModelContainer(
            for: MissionThreadRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mission_thread_v1.json")
        let v1Data = try Data(contentsOf: fixtureURL)
        let v1Thread = try MissionThreadCodec.decode(v1Data)
        let row = MissionThreadRecord(v1Thread, payloadData: v1Data)
        container.mainContext.insert(row)
        try container.mainContext.save()

        let store = SwiftDataMissionThreadStore(container: container, clock: { Self.now })
        let loaded = try #require(store.load().threads.first)
        #expect(loaded.id == v1Thread.id)
        #expect(loaded.revision == v1Thread.revision)
        #expect(try MissionThreadCodec.schemaVersion(in: row.payloadData) == 2)
        #expect(try MissionThreadCodec.decode(row.payloadData) == loaded)
    }

    @Test("Completed threads leave continuation storage without touching History")
    @MainActor
    func completedEvicts() throws {
        let store = InMemoryMissionThreadStore()
        var thread = deckThread(id: "done")
        try store.save(thread)
        var staleCompletion = thread
        staleCompletion.phase = .completed
        #expect(throws: MissionThreadStoreError.conflictingRevision(thread.revision)) {
            try store.save(staleCompletion)
        }
        #expect(store.load().threads.map(\.id) == ["done"])

        thread.phase = .completed
        thread.advanceRevision(at: Self.now.addingTimeInterval(10))
        try store.save(thread)
        #expect(store.load().threads.isEmpty)
    }

    @Test("A terminal phase with a live question remains resumable until explicitly answered")
    @MainActor
    func terminalQuestionPersists() throws {
        let store = InMemoryMissionThreadStore()
        var thread = deckThread(id: "terminal-question")
        let product = try #require(thread.candidates.first)
        thread.kit = [KitItem(product: product)]
        thread.remainingDeckIDs = []
        thread.phase = .completed
        let snapshot = MissionKitSnapshot(
            id: "kit-final", revision: thread.revision,
            items: thread.kit.map(MissionKitSnapshotItem.init)
        )
        thread.timeline.append(MissionThreadEvent(
            id: "kit-prompt", sequence: thread.nextTimelineSequence,
            kind: .assistantMessage, text: "Review?", createdAt: Self.now,
            blocks: [.kit(snapshot)]
        ))
        let pending = try thread.installInteraction(
            promptEventID: "kit-prompt", subjectRevision: thread.revision,
            kind: .cartReview, question: "Review?",
            options: [MissionInteractionOption(id: "end", label: "End")],
            allowsFreeText: false,
            resolver: .kit(snapshotID: snapshot.id, revision: snapshot.revision), createdAt: Self.now
        )
        try store.save(thread)
        #expect(store.load().threads.first?.pendingInteraction == pending)

        let submission = MissionInteractionSubmission(
            threadID: thread.id, interactionID: pending.id,
            interactionGeneration: pending.interactionGeneration,
            subjectRevision: pending.subjectRevision, idempotencyID: "end-answer",
            answer: .option(id: "end")
        )
        try thread.resolveInteraction(submission)
        thread.advanceRevision(at: Self.now.addingTimeInterval(5))
        try store.save(thread)
        #expect(store.load().threads.isEmpty)
    }

    @Test("An option persisted before isDestructive existed decodes as non-destructive")
    func legacyOptionDecodesAsNonDestructive() throws {
        // Exactly the shape already sitting in every installed copy's thread store. Throwing here
        // would quarantine a whole mission over a presentation hint.
        let legacy = Data(#"{"id":"end","label":"End mission"}"#.utf8)
        let decoded = try JSONDecoder().decode(MissionInteractionOption.self, from: legacy)

        #expect(decoded.id == "end")
        #expect(decoded.label == "End mission")
        #expect(decoded.isDestructive == false)
    }

    @Test("isDestructive survives a persistence round-trip")
    func destructiveFlagRoundTrips() throws {
        let option = MissionInteractionOption(id: "end", label: "End mission", isDestructive: true)
        let data = try JSONEncoder().encode(option)

        #expect(try JSONDecoder().decode(MissionInteractionOption.self, from: data) == option)
    }

    // MARK: Parts — which decision a candidate belongs to

    /// A pour-over kit whose deck is deliberately in the *opposite* order to the plan, so deck order
    /// and part order can't be mistaken for each other.
    private func coffeeThread(reversed: Bool = true) -> MissionThread {
        var thread = planningThread(id: "coffee")
        thread.task = SeedData.coffee
        thread.plan = zip(SeedData.coffee.plan, SeedData.coffee.searchQueries).enumerated().map {
            MissionPlanPart(id: "part-\($0.offset)", label: $0.element.0, query: $0.element.1)
        }
        thread.candidates = reversed ? SeedData.coffeeProducts.reversed() : SeedData.coffeeProducts
        thread.baseCandidates = thread.candidates
        thread.remainingDeckIDs = thread.candidates.map(\.id)
        thread.phase = .deckReady
        thread.advanceRevision(at: Self.now.addingTimeInterval(1))
        return thread
    }

    @Test("A multi-part kit asks about the first plan part the kit doesn't cover yet")
    func nextCardWalksThePlan() {
        var thread = coffeeThread()
        // Deck order would offer the mat; the plan's first open part is the kettle.
        #expect(thread.remainingDeck.first?.id == "coffee.mat")
        #expect(thread.nextCard?.id == "coffee.kettle")

        // Keep it, and the mission moves on to the next open part rather than back to deck order.
        let kettle = SeedData.coffeeProducts.first { $0.id == "coffee.kettle" }!
        thread.kit = [KitItem(product: kettle)]
        thread.remainingDeckIDs.removeAll { $0 == kettle.id }
        #expect(thread.nextCard?.id == "coffee.grinder")
    }

    @Test("A part with nothing left on the deck cannot stall the mission")
    func nextCardFallsThroughAnUnshoppablePart() {
        var thread = coffeeThread()
        // Nothing here answers "Gooseneck kettle" or "Burr grinder" any more.
        thread.remainingDeckIDs = ["coffee.mat", "coffee.dripper"]
        #expect(thread.nextCard?.id == "coffee.dripper", "the first open part the deck can still answer")
    }

    @Test("A single-item mission keeps plain deck order")
    func nextCardLeavesShortlistsAlone() {
        var thread = coffeeThread()
        thread.task = SeedData.coffee.settingSingleItem(true)
        #expect(thread.nextCard?.id == thread.remainingDeck.first?.id)
    }

    @Test("Alternatives are the same part's other candidates, never other parts")
    func alternativesAreSamePart() {
        var thread = coffeeThread(reversed: false)
        let kettle = thread.candidates.first { $0.id == "coffee.kettle" }!
        #expect(thread.alternatives(to: kettle).isEmpty, "one kettle in the deck is one option")

        // A second kettle from the same search *is* an alternative; the mat still isn't.
        let second = Product(
            id: "coffee.kettle2", name: "Stagg Pour-Over Kettle", shop: kettle.shop, price: 79,
            rating: 4.6, reviews: 90, rationale: "", symbol: "cup.and.saucer",
            gradient: SeedData.Gradient.ochre,
            variants: [Variant(id: "coffee.kettle2.v", title: "Standard", price: 79, checkoutURL: nil)]
        )
        thread.candidates.append(second)
        thread.remainingDeckIDs.append(second.id)
        #expect(thread.alternatives(to: kettle).map(\.id) == ["coffee.kettle2"])
    }

    /// The deterministic planner's one-part framing, which is what most typed goals actually get.
    @Test("A kit mission whose plan never divided anything offers nothing to compare")
    func alternativesNeedAPartitionedPool() {
        var thread = coffeeThread(reversed: false)
        thread.plan = [MissionPlanPart(id: "only", label: "Set up my pour-over corner", query: "pour over corner")]
        thread.candidateParts = Dictionary(
            uniqueKeysWithValues: thread.candidates.map { ($0.id, "pour over corner") }
        )
        let kettle = thread.candidates.first { $0.id == "coffee.kettle" }!
        #expect(thread.alternatives(to: kettle).isEmpty,
                "one search that returned everything is not evidence the mat is a cheaper kettle")
    }

    @Test("A single-item mission compares its whole deck, attributed or not")
    func alternativesOnAShortlist() {
        var thread = coffeeThread(reversed: false)
        thread.task = SeedData.coffee.settingSingleItem(true)
        let kettle = thread.candidates.first { $0.id == "coffee.kettle" }!
        #expect(thread.alternatives(to: kettle).count == thread.remainingDeck.count - 1)
    }

    @Test("Continuation store is bounded newest-first")
    @MainActor
    func boundedContinuationList() throws {
        let store = InMemoryMissionThreadStore()
        for index in 0...InMemoryMissionThreadStore.cap {
            var thread = planningThread(
                id: "thread-\(index)", at: Self.now.addingTimeInterval(Double(index))
            )
            thread.advanceRevision(at: Self.now.addingTimeInterval(Double(index)))
            try store.save(thread)
        }
        let loaded = store.load().threads
        #expect(loaded.count == InMemoryMissionThreadStore.cap)
        #expect(loaded.first?.id == "thread-\(InMemoryMissionThreadStore.cap)")
        #expect(!loaded.contains { $0.id == "thread-0" })
    }
}
