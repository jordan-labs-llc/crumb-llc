import Foundation
import Observation
import CrumbKit

/// Top-level navigation state for the Missions → Mission thread → Cart flow.
///
/// `onboarding` is the first-run entry: shown only when no ``TasteProfile`` has been
/// persisted yet, so a returning user never sees it.
enum Route: Hashable {
    case onboarding
    case missions
    /// One stable workspace whose active artifact changes from plan to product deck in place.
    case missionThread
    case cart
    /// The timeline of past missions, reached from the app header.
    case history
    /// A read-only detail of one past mission's kit (the selected ``AppModel/selectedHistoryEntry``).
    case historyDetail
    /// The roster of people you shop for (the gift feature), reached from the app header.
    case people
}

/// The one response surface the mission UI renders. All choices and text are submitted against the
/// frozen interaction identity, so scrollback and asynchronously changing artifacts are read-only.
struct MissionDockState: Equatable {
    enum Mode: Equatable { case freeText, singleChoice, confirmation, working, recovery, unavailable }

    let mode: Mode
    let interaction: MissionPendingInteraction?
    let question: String
    let options: [MissionInteractionOption]
    let allowsFreeText: Bool
    let placeholder: String
    let isEnabled: Bool
    let showsSaveRecovery: Bool
}

enum MissionSubmissionResult: Equatable {
    case applied
    case unsaved
    case rejected
}

/// One row of a mission's plan: a human label plus the catalog query that finds it. The planner
/// produces these; the thread renders them as a read-only in-thread notice (multi-part kits
/// only), and plan feedback flows conversationally — typed text folds into the goal or reworks
/// the picks — rather than through editing controls.
typealias PlanPart = MissionPlanPart

extension ShoppingTask {
    /// An immutable copy with a new plan + queries, keeping the mission's identity (id, title,
    /// note, accent). Used to commit the user's plan edits back before curating.
    func rebuilt(plan: [String], searchQueries: [String]) -> ShoppingTask {
        ShoppingTask(
            id: id,
            title: title,
            subtitle: subtitle,
            plan: plan,
            curatorNote: curatorNote,
            accentHex: accentHex,
            candidateIDs: candidateIDs,
            searchQueries: searchQueries,
            isSingleItem: isSingleItem
        )
    }
}

/// The app's single source of truth.
///
/// `@Observable` (Observation framework) and `@MainActor`. Owns navigation `route`, the
/// selected mission, the user's `kit`, the `tasteProfile`, and the injected `UCPClient`
/// + `CuratorEngine` seams. Registered as an App Intents dependency at launch so Siri /
/// Shortcuts can drive navigation (see ``planMission(goal:)``).
@MainActor
@Observable
final class AppModel {

    // MARK: Navigation

    var route: Route = .missions
    /// The sole writable owner of the active mission's task, plan, products, deck, kit, recipient,
    /// and conversation. The view-facing properties below are projections into this aggregate.
    private(set) var activeThread: MissionThread? = nil
    private(set) var incompleteThreads: [MissionThread] = []
    private(set) var threadLoadFailures: [MissionThreadLoadFailure] = []
    private(set) var threadPersistenceWarning: String?
    /// The exact last aggregate accepted by the store. Discard restores this value; it never tries
    /// to infer durable state from the timeline or from the current in-memory revision.
    private var lastDurableActiveThread: MissionThread?
    private var unsavedThreadID: String?
    private var interactionConstructionFailure: String?

    var activeThreadID: String? { activeThread?.id }
    var selectedTask: ShoppingTask? { activeThread?.task }

    // MARK: Planning (the free-text composer → plan)

    /// `true` while the on-device planner is decomposing a typed goal into a mission. Drives the
    /// composer's "thinking" state.
    private(set) var isPlanning = false

    /// A short, friendly message when a typed goal isn't something Crumb can shop for (a
    /// question, nonsense, empty). `nil` when the last goal planned cleanly. Shown inline under
    /// the composer instead of routing into an empty plan.
    private(set) var planDecline: String?

    /// Which planner tier produced the current plan. Drives the honest "smart planning
    /// unavailable" note on the Plan screen (see ``plannerFallbackNote``).
    private(set) var plannerTier: PlannerTier?

    /// A short, user-facing note when Crumb wanted its AI planner but fell back to the simple
    /// deterministic plan (older device, Apple Intelligence off, offline). `nil` otherwise.
    var plannerFallbackNote: String? { plannerTier?.fallbackNote }

    /// The editable parts of the current plan — the curator's decomposition, which the user can
    /// reword / add to / trim on the Plan screen before curating. Committed back into the
    /// mission's queries when they tap "Curate my kit" (see ``beginCuration()``).
    var draftParts: [PlanPart] { activeThread?.plan ?? [] }

    /// `true` when the plan has been edited (or freshly planned) since the last successful
    /// candidate load, so "Curate my kit" knows to re-run the search rather than reuse a
    /// stale deck.
    private var planDirty = false

    /// Recently typed goals, most-recent-first, surfaced as quick-tap chips in the composer.
    private(set) var recentGoals: [String] = []

    // MARK: Domain state

    var kit: [KitItem] { activeThread?.kit ?? [] }

    // MARK: History (the persisted record of past missions)

    /// All saved missions, most-recent-first — the timeline's data. Refreshed from the store after
    /// every write so the History screen reflects the latest kit, outcome, or deletion.
    private(set) var historyEntries: [HistoryEntry] = []

    /// The entry the read-only History detail is showing (set by ``openHistoryDetail(_:)``).
    private(set) var selectedHistoryEntry: HistoryEntry?

    /// When set, the re-shop sheet for a past entry is presented (the snapshot's per-item buy links,
    /// honest about gone links — the History twin of ``handoff``).
    var reshopEntry: HistoryEntry?

    /// The id of the entry for the *current* shopping session, or `nil` before the kit first reaches
    /// the cart this session. Stable per `enterPlan`, so re-reaching the cart updates the same entry
    /// (and a real checkout handoff flips that entry's outcome). A new mission starts a fresh id.
    private var currentHistoryEntryID: String? { activeThread?.historyEntryID }

    /// The user's *original* free-text goal for this session, so a saved entry stores the real goal
    /// (not `ShoppingTask.title`, which the planner title-cases and length-caps) and "Plan this
    /// again" re-plans exactly what they typed. `nil` for the seed-mission path, where the task's
    /// own title is the faithful goal.
    private var currentMissionGoal: String? { activeThread?.goal }

    /// The current per-recipient History filter (the chip row at the top of the timeline). `.all` by
    /// default; `.yourself` / `.person(id)` narrow the timeline to one person's kits.
    var historyRecipientFilter: HistoryRecipientFilter = .all

    /// The history entries passing the active recipient filter — what the timeline actually renders.
    var filteredHistoryEntries: [HistoryEntry] {
        HistoryFacets.apply(historyRecipientFilter, to: historyEntries)
    }

    /// The filter chips a history warrants (All · You · each person with a saved gift kit), tinted.
    var historyFacets: [HistoryRecipientFacet] {
        HistoryFacets.facets(historyEntries, ownerAccentHex: Self.ownerAccentHex)
    }

    /// The aggregate "since you started" stat line for the History header — over the **filtered**
    /// set, so "everything for Mom" gets its own honest totals.
    var historyStats: HistoryStats { HistoryStats(entries: filteredHistoryEntries) }

    /// The user's taste — the single persisted piece of domain state. Read-only to views;
    /// all edits flow through ``updateTaste(_:)`` so every change is persisted *and* re-curates
    /// the live deck.
    private(set) var tasteProfile: TasteProfile

    // MARK: Recipients (the people you shop *for* — the gift feature)

    /// The saved roster of people you shop for, most-recently-added-first. Refreshed from the store
    /// after every write. "Yourself" is **not** here — it's the owner ``tasteProfile`` (the absence
    /// of a recipient).
    private(set) var recipients: [Recipient] = []

    /// The composer's "Who's this for?" selection — the person a *new* mission will be for, or `nil`
    /// for Yourself. Opt-in per mission and reset to Yourself whenever the composer is returned to,
    /// so a new mission always defaults to Yourself (zero regression to today's flow).
    var composerRecipient: Recipient?

    /// The **active** mission's recipient (`nil` = Yourself). Set when a mission is started for
    /// someone and carried through plan → curate → refine → recap; reset on the next `enterPlan`.
    /// This is the switch behind ``activeTaste``: the whole curation pipeline reads *their* taste.
    var activeRecipient: Recipient? { activeThread?.recipient }

    /// The taste the *current mission* curates through: the active recipient's when shopping for
    /// someone, else the owner's. **Every** seam call that used to pass `tasteProfile` now passes
    /// this, so "become their shopper" is a single source of truth.
    var activeTaste: TasteProfile { activeThread?.tasteSnapshot ?? tasteProfile }

    /// The lean recipient snapshot threaded into the curator + recap as gift context (and stamped
    /// onto the saved history entry). `nil` for an owner mission.
    var activeRecipientRef: RecipientRef? { activeRecipient.map(RecipientRef.init) }

    /// The owner's accent for the History "You" facet chip (the app's default pine).
    static let ownerAccentHex: UInt32 = 0x1C4B43

    /// A small, on-brand earthy palette assigned to new people by add-order, so each person gets a
    /// distinct tint for their cards/chips (like a mission's accent).
    static let recipientAccents: [UInt32] = [
        0x9A6A4F, 0x4F6D7A, 0x7A5C7E, 0x5E7A52, 0xB07D48, 0x55708A, 0x8A6D3B, 0x6E5774,
    ]

    /// The opt-in "make this part of <whose> taste" copy on the refinement bar — addressed to the
    /// active recipient during a gift mission, else to the owner.
    var saveToTasteLabel: String {
        if let name = activeRecipient?.name { return "Make this part of \(name)'s taste" }
        return "Make this part of your taste"
    }

    /// The compact dock-chip variant of ``saveToTasteLabel`` — same action, chip-sized copy.
    var saveToTasteChipLabel: String {
        if let name = activeRecipient?.name { return "Save to \(name)'s taste" }
        return "Save to taste"
    }

    /// `true` while a profile edit is re-ranking and re-voicing the on-screen deck. Drives the
    /// Curate screen's "re-reading your taste" shimmer so the personalization is *felt*.
    private(set) var isRecurating = false

    // MARK: Conversational refinement (talk back to the curator)

    /// The running per-mission refinement conversation, oldest-first ("make it cheaper", then
    /// "but keep the kettle"). Fed to the interpreter every time so refinements compose and
    /// persisted with the mission thread so a resumed mission keeps its conversational context.
    var refinementTurns: [String] { activeThread?.refinementTurns ?? [] }

    /// `true` while a refinement is reworking the on-screen deck. Drives the Curate screen's
    /// "Reworking the deck…" shimmer (the sibling of `isRecurating`).
    private(set) var isReworking = false

    /// Which interpreter tier read the latest refinement. Drives the honest "smart refining
    /// unavailable" note on the Curate screen (see ``refinementFallbackNote``).
    private(set) var refinementTier: RefinementTier?

    /// A short, user-facing note when Crumb wanted its AI interpreter but fell back to the
    /// deterministic refinement read. `nil` otherwise.
    var refinementFallbackNote: String? { refinementTier?.fallbackNote }

    /// `true` once at least one refinement has been applied this mission (and not yet saved or
    /// reset), so the Curate screen can offer the quiet "make this part of your taste" affordance.
    private(set) var canSaveRefinementToTaste = false

    /// The directives applied this mission, kept so "save to taste" can deterministically fold
    /// them into the profile when no model is available to re-read the text (sim/CI).
    private var refinementDirectives: [RefinementDirective] { activeThread?.refinementDirectives ?? [] }

    /// The deck as first dealt for this mission, before any refinement — the snapshot
    /// ``resetRefinements()`` restores so Reset truly undoes the conversation.
    private var baseCandidates: [Product] { activeThread?.baseCandidates ?? [] }

    /// The quick-refinement chips shown on the Curate screen, fit to the current mission
    /// (tea → Organic/Caffeine-free/Bolder; a hike → Warmer/Lighter/Durable). Set to the
    /// deterministic floor synchronously in ``enterPlan(with:recipient:)`` so the bar renders
    /// instantly and headless screenshots stay stable, then upgraded in place by the
    /// ``RefineChipSuggester`` seam when an on-device model tier is up. See issue #25.
    private(set) var refineChips: [RefineChip] = []

    /// Ranked candidate products for the selected mission.
    var candidates: [Product] { activeThread?.candidates ?? [] }
    /// The remaining swipe deck (candidates not yet decided on).
    var deck: [Product] {
        guard let thread = activeThread else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: thread.candidates.map { ($0.id, $0) })
        return thread.remainingDeckIDs.compactMap { byID[$0] }
    }

    /// Where the Plan screen's candidate load currently stands.
    enum LoadState: Equatable {
        case idle
        case loading   // "scanning shops…" — no products yet, the Plan scan is blocking
        case refining  // products are on screen and actionable; gather/curation still settling (#57)
        case loaded    // results in `candidates` (possibly empty == "no matches")
        case failed    // every query errored (broker down / offline) — retryable
    }

    private(set) var loadState: LoadState = .idle

    /// `true` once the deck is actionable (``LoadState/refining``) but the settle has run past
    /// ``curationSettleWindow`` — the Curate screen downgrades the blocking-looking "Curating your
    /// picks…" spinner to a quiet, honest, non-blocking status so the user is never left staring at
    /// an indefinite spinner over a usable deck (#57). Reset the moment the deck settles or reloads.
    private(set) var curationRefiningOvertime = false

    /// How long the "Curating your picks…" spinner may show over an actionable deck before it
    /// downgrades to a non-blocking status (#57). An instance `var` (not a `static let`) purely so
    /// tests can shrink it to exercise the downgrade/timeout without real-time waits.
    var curationSettleWindow: Double = 12
    /// The hard settle deadline: if the curator's ranking/voice hasn't returned within this window,
    /// the load settles with the streamed, deterministically-voiced deck rather than holding the
    /// user behind a hung on-device model turn (#57). Well above a healthy on-device settle.
    var curationSettleDeadline: Double = 60

    /// Fires ``curationRefiningOvertime`` once the settle window elapses while still refining;
    /// cancelled the moment the deck settles, fails, or a new load starts.
    private var settleWatchdog: Task<Void, Never>?

    /// Which curator voice produced the current deck. Drives the honest "AI curator
    /// unavailable" note on the Curate screen (see ``curatorFallbackNote``).
    private(set) var curatorTier: CuratorTier?

    /// A short, user-facing note when Crumb wanted its AI curator but had to fall back to
    /// the deterministic voice (older device, Apple Intelligence off, quota spent, offline).
    /// `nil` when the AI curator ran, or when rule-based is the configured default.
    var curatorFallbackNote: String? { curatorTier?.fallbackNote }

    /// `true` while Crumb is "scanning shops" on the Plan screen — no products yet, blocking.
    var isScanning: Bool { loadState == .loading }
    /// `true` while the deck is on screen and actionable but the gather/curation is still settling
    /// in the background (#57). Distinct from ``isScanning``: the user can already swipe and add.
    var isRefining: Bool { loadState == .refining }
    /// `true` when the load failed outright (distinct from a successful empty result).
    var loadFailed: Bool { loadState == .failed }

    // MARK: Overlay state

    var isShowingTasteProfile = false
    /// When set, the per-shop checkout handoff sheet is presented.
    var handoff: Handoff?

    /// The active multi-merchant checkout preparation. A workflow snapshots the kit and keeps one
    /// stable idempotency key per merchant for its entire lifetime, including targeted retries.
    /// This prevents a double tap (or a retry after a timeout) from creating duplicate merchant
    /// checkouts while still allowing every shop to succeed or fail independently.
    var checkoutWorkflow: CheckoutWorkflow?

    /// A per-shop checkout handoff. `url` is the resolved UCP `continue_url` (or the
    /// merchant storefront fallback); `nil` means no handoff target exists for this shop —
    /// the sheet surfaces that honestly instead of the button silently doing nothing.
    struct Handoff: Identifiable, Hashable {
        let shop: Shop
        let url: URL?
        let items: [KitItem]
        var id: String { shop.id }
    }

    struct CheckoutWorkflow: Identifiable, Hashable {
        let id: UUID
        var merchants: [MerchantCheckout]

        var isPreparing: Bool { merchants.contains { $0.state == .preparing } }
        var preparedCount: Int { merchants.count { $0.isReady } }
        var completedCount: Int { merchants.count { $0.sandbox?.phase == .completed } }
    }

    struct MerchantCheckout: Identifiable, Hashable {
        let shop: Shop
        let items: [KitItem]
        let idempotencyKey: String
        var state: State
        var sandbox: SandboxCheckout?
        var id: Shop.ID { shop.id }

        var isReady: Bool {
            guard case .prepared(let session) = state else { return false }
            if sandbox != nil {
                return session.status == .readyForComplete && sandbox?.isDirty == false
            }
            return session.status == .requiresEscalation && session.continueURL != nil
        }

        enum State: Hashable {
            case preparing
            case prepared(CheckoutSession)
            case unsupported(String, fallbackURL: URL?)
            case failed(String)

            var isPrepared: Bool {
                if case .prepared(let session) = self,
                   session.status == .requiresEscalation,
                   session.continueURL != nil { return true }
                return false
            }
        }
    }

    struct SandboxCheckout: Hashable {
        enum Phase: Hashable { case contact, updating, shipping, review, completing, completed, expired, failed(String) }
        var phase: Phase = .contact
        var firstName = ""
        var lastName = ""
        var email = ""
        var phone = ""
        var street = ""
        var city = ""
        var region = ""
        var postalCode = ""
        var country = "US"
        var shippingSelections: [String: String] = [:]
        var acknowledgedFingerprint: String?
        var authoritativeFingerprint: String?
        var updateKey: String?
        var completionKey: String?

        var fingerprint: String {
            [firstName, lastName, email, phone, street, city, region, postalCode, country]
                .joined(separator: "\u{1F}") + "|" + shippingSelections.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        var isDirty: Bool { authoritativeFingerprint != fingerprint }
        var isAcknowledged: Bool { acknowledgedFingerprint == fingerprint && !isDirty }

        var canSubmitContact: Bool {
            !firstName.trimmingCharacters(in: .whitespaces).isEmpty
                && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
                && email.contains("@") && !street.isEmpty && !city.isEmpty
                && !region.isEmpty && !postalCode.isEmpty && country.count == 2
        }
    }

    // MARK: Dependencies (seams)

    let ucp: any UCPClient
    let curator: any CuratorEngine
    let tasteExtractor: any TasteExtractor
    let planner: any MissionPlanner
    let refiner: any RefinementInterpreter
    /// Suggests the mission-fit quick-refinement chips for the Curate bar. Defaults to the
    /// deterministic taxonomy floor (no model, mock-safe); the app wires the model-backed variant.
    let chipSuggester: any RefineChipSuggester
    let recapWriter: any RecapWriter
    /// Drops clearly off-topic catalog results *before* the curator ranks/voices them, so a stray
    /// live result never reaches the deck with a confident rationale. Defaults to the deterministic
    /// floor (no model, mock-safe) so existing tests and the scaffold need nothing.
    let relevanceGate: any RelevanceGate
    /// Gathers the mission's candidate pool (the search + relevance phase). Defaults to the
    /// deterministic floor (the exact fan-out + gate the pipeline ran inline, no model, mock-safe);
    /// the app wires ``AppleFoundationMissionOrchestrator``, which lets the model *drive* the search
    /// via Tools when one is up and degrades to this floor otherwise.
    let orchestrator: any MissionOrchestrator
    private let tasteStore: any TasteStore
    private let recentsStore: any RecentMissionsStore
    private let historyStore: any HistoryStore
    private let recipientStore: any RecipientStore
    private let threadStore: any MissionThreadStore
    /// Injected wall-clock — used only at save time for an entry's `createdAt` (and the session
    /// entry id). A closure so tests can pin time and keep timeline grouping deterministic; pure
    /// logic never calls `Date()` directly (see [[ios-sim-available-xcode27]] build notes).
    private let clock: () -> Date

    /// Transient generations for in-flight work. Persisted pending-operation metadata supports
    /// crash recovery; these IDs additionally reject late completions after a same-thread retry.
    private var activeOperationIDs: [MissionOperationKind: String] = [:]
    private var operationTasks: [MissionOperationKind: Task<Void, Never>] = [:]
    /// Handles for fire-and-forget entry points. Operation IDs reject stale commits; these handles
    /// additionally propagate cancellation so superseded model/tool work stops consuming resources.
    private var launchedOperationTasks: [MissionOperationKind: Task<Void, Never>] = [:]

    /// Builds the app model, restoring the persisted ``TasteProfile`` if one exists.
    ///
    /// The presence of a stored profile is also the first-run signal: with none, the app opens
    /// on ``Route/onboarding`` (and falls back to the seed profile as the editable starting
    /// point); with one, it opens straight on Missions. `tasteStore` and `tasteExtractor`
    /// default to the keyless in-memory / manual doubles so existing tests and the mock
    /// scaffold need no model or disk.
    init(
        ucp: any UCPClient,
        curator: any CuratorEngine,
        tasteStore: any TasteStore = InMemoryTasteStore(),
        tasteExtractor: any TasteExtractor = ManualTasteExtractor(),
        planner: any MissionPlanner = RuleBasedMissionPlanner(),
        refiner: any RefinementInterpreter = RuleBasedRefinementInterpreter(),
        chipSuggester: any RefineChipSuggester = RuleBasedRefineChipSuggester(),
        recapWriter: any RecapWriter = RuleBasedRecapWriter(),
        relevanceGate: any RelevanceGate = RuleBasedRelevanceGate(),
        orchestrator: any MissionOrchestrator = DeterministicMissionOrchestrator(),
        recentsStore: any RecentMissionsStore = InMemoryRecentMissionsStore(),
        historyStore: any HistoryStore = InMemoryHistoryStore(),
        recipientStore: any RecipientStore = InMemoryRecipientStore(),
        threadStore: any MissionThreadStore = InMemoryMissionThreadStore(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.ucp = ucp
        self.curator = curator
        self.tasteStore = tasteStore
        self.tasteExtractor = tasteExtractor
        self.planner = planner
        self.refiner = refiner
        self.chipSuggester = chipSuggester
        self.recapWriter = recapWriter
        self.relevanceGate = relevanceGate
        self.orchestrator = orchestrator
        self.recentsStore = recentsStore
        self.historyStore = historyStore
        self.recipientStore = recipientStore
        self.threadStore = threadStore
        self.clock = clock

        let stored = tasteStore.loadProfile()
        self.tasteProfile = stored ?? SeedData.defaultTasteProfile
        self.route = stored == nil ? .onboarding : .missions
        self.recentGoals = recentsStore.loadRecents()
        self.historyEntries = historyStore.loadEntries()
        self.recipients = recipientStore.loadRecipients()
        let loadedThreads = threadStore.load()
        self.incompleteThreads = loadedThreads.threads
        self.threadLoadFailures = loadedThreads.failures
    }

    // MARK: Mission thread transactions

    /// The one mutation choke point for durable mission state. A transaction updates memory first
    /// so the current session stays usable if storage fails, then performs a revision-ordered save.
    private func mutateActiveThread(_ mutation: (inout MissionThread) -> Void) {
        guard var thread = activeThread else { return }
        interactionConstructionFailure = nil
        // Advance first so any interaction installed by the transaction can freeze this exact
        // subject revision and pass aggregate validation before it is persisted.
        thread.revision += 1
        thread.updatedAt = clock()
        mutation(&thread)
        if let failure = interactionConstructionFailure {
            threadPersistenceWarning = "This conversation couldn't continue safely: \(failure)"
            interactionConstructionFailure = nil
            return
        }
        activeThread = thread
        upsertThreadInMemory(thread)
        persistThread(thread)
    }

    private func installActiveThread(_ thread: MissionThread, persist: Bool = true) {
        if let failure = interactionConstructionFailure {
            threadPersistenceWarning = "This conversation couldn't continue safely: \(failure)"
            interactionConstructionFailure = nil
            return
        }
        activeThread = thread
        upsertThreadInMemory(thread)
        if persist { persistThread(thread) }
        else {
            lastDurableActiveThread = thread
            unsavedThreadID = nil
        }
    }

    private func upsertThreadInMemory(_ thread: MissionThread) {
        incompleteThreads.removeAll { $0.id == thread.id }
        guard thread.phase != .completed, thread.phase != .abandoned else { return }
        incompleteThreads.append(thread)
        incompleteThreads.sort { $0.updatedAt > $1.updatedAt }
        if incompleteThreads.count > 12 { incompleteThreads.removeLast(incompleteThreads.count - 12) }
    }

    @discardableResult
    private func persistThread(_ thread: MissionThread, committedID: String? = nil) -> Bool {
        do {
            try threadStore.save(thread)
            threadPersistenceWarning = nil
            unsavedThreadID = nil
            lastDurableActiveThread = thread
            if activeThread?.id == thread.id, activeThread?.blockingRecovery != nil {
                activeThread?.blockingRecovery = nil
            }
            return true
        } catch {
            unsavedThreadID = thread.id
            threadPersistenceWarning = "This mission is available now, but couldn't be saved on this device."
            if activeThread?.id == thread.id {
                if let committedID {
                    activeThread?.blockingRecovery = .saveCommittedMutation(
                        failedRevision: thread.revision, idempotencyID: committedID
                    )
                } else if thread.pendingInteraction != nil {
                    activeThread?.blockingRecovery = .savePendingInteraction(failedRevision: thread.revision)
                } else {
                    activeThread?.blockingRecovery = .saveCommittedMutation(
                        failedRevision: thread.revision,
                        idempotencyID: thread.decisions.last?.id ?? "thread-\(thread.revision)"
                    )
                }
                if let blocked = activeThread { upsertThreadInMemory(blocked) }
            }
            return false
        }
    }

    func retryThreadPersistence() {
        guard var thread = activeThread, unsavedThreadID == thread.id else { return }
        let queued = thread.pendingOperation?.retry
        thread.blockingRecovery = nil
        activeThread = thread
        if persistThread(thread), let queued { runQueuedRetry(queued) }
    }

    func discardUnsavedThreadChanges() {
        guard let active = activeThread, unsavedThreadID == active.id else { return }
        cancelOperations()
        if let durable = lastDurableActiveThread, durable.id == active.id {
            activeThread = durable
            upsertThreadInMemory(durable)
        } else {
            activeThread = nil
            incompleteThreads.removeAll { $0.id == active.id }
            try? threadStore.delete(id: active.id)
            route = .missions
        }
        unsavedThreadID = nil
        threadPersistenceWarning = nil
    }

    private func cancelOperations() {
        for task in operationTasks.values { task.cancel() }
        for task in launchedOperationTasks.values { task.cancel() }
        operationTasks.removeAll()
        launchedOperationTasks.removeAll()
        activeOperationIDs.removeAll()
        settleWatchdog?.cancel()
        isPlanning = false
        isReworking = false
        isRecurating = false
        curationRefiningOvertime = false
    }

    private func beginOperation(_ kind: MissionOperationKind) -> String? {
        guard activeThread != nil else { return nil }
        operationTasks[kind]?.cancel()
        let id = UUID().uuidString
        activeOperationIDs[kind] = id
        return id
    }

    private func operationIsCurrent(_ kind: MissionOperationKind, id: String, threadID: String) -> Bool {
        activeThread?.id == threadID && activeOperationIDs[kind] == id
    }

    private func finishOperation(_ kind: MissionOperationKind, id: String) {
        guard activeOperationIDs[kind] == id else { return }
        activeOperationIDs[kind] = nil
        operationTasks[kind] = nil
    }

    private func replaceDeck(_ products: [Product]) {
        mutateActiveThread { $0.remainingDeckIDs = products.map(\.id) }
    }

    private func replaceCandidates(_ products: [Product], base: [Product]? = nil) {
        mutateActiveThread {
            $0.candidates = products
            if let base { $0.baseCandidates = base }
        }
    }

    var threadShowsDeck: Bool {
        guard let thread = activeThread else { return false }
        return thread.phase == .deckReady || (thread.phase == .gathering && !thread.candidates.isEmpty)
    }

    var threadComposerEnabled: Bool {
        guard let thread = activeThread else { return false }
        if isPlanning || isReworking || isScanning { return false }
        return thread.phase == .declined || thread.phase == .deckReady
    }

    var threadComposerPlaceholder: String {
        guard let thread = activeThread else { return "Start a mission…" }
        if isPlanning { return "Starting your mission…" }
        if isScanning { return "Searching the shops…" }
        if isReworking { return "Reworking your picks…" }
        switch thread.phase {
        case .declined: return "Try another shopping goal…"
        case .planReady: return "Pick the search back up above"
        case .deckReady: return "Tell Crumb what to change…"
        case .failed: return "Retry from the message above"
        default: return "Crumb is working…"
        }
    }

    var missionDockState: MissionDockState {
        guard let thread = activeThread else {
            return MissionDockState(mode: .unavailable, interaction: nil, question: "Mission unavailable",
                                    options: [], allowsFreeText: false, placeholder: "Start a mission…",
                                    isEnabled: false, showsSaveRecovery: false)
        }
        if thread.blockingRecovery != nil || unsavedThreadID == thread.id {
            return MissionDockState(mode: .recovery, interaction: thread.pendingInteraction,
                                    question: "Save this turn before continuing.",
                                    options: [
                                        MissionInteractionOption(id: "save-again", label: "Save again"),
                                        MissionInteractionOption(id: "discard", label: "Discard"),
                                    ], allowsFreeText: false, placeholder: "Save or discard this turn",
                                    isEnabled: true, showsSaveRecovery: true)
        }
        guard let interaction = thread.pendingInteraction else {
            return MissionDockState(mode: .working, interaction: nil, question: "Crumb is working…",
                                    options: [], allowsFreeText: false, placeholder: threadComposerPlaceholder,
                                    isEnabled: false, showsSaveRecovery: false)
        }
        return MissionDockState(
            mode: Self.dockMode(for: interaction, hasQueuedRetry: thread.retry != nil),
            interaction: interaction,
            question: interaction.question,
            options: interaction.options,
            allowsFreeText: interaction.allowsFreeText,
            placeholder: dockPlaceholder(for: interaction),
            isEnabled: true,
            showsSaveRecovery: false
        )
    }

    /// Which register the dock voices a question in.
    ///
    /// `hasQueuedRetry` is the honest signal for "something actually failed", because
    /// ``MissionInteractionKind/retry`` covers two unrelated situations. `installRetryQuestion`
    /// resumes a turn that really did fail, and every one of its call sites sets `thread.retry`;
    /// `installResumeShoppingQuestion` merely asks a freshly planned mission whether to start, and
    /// never sets it. Deriving the mode from the kind alone therefore dressed "Should I start
    /// shopping?" in the ochre `exclamationmark.icloud` treatment reserved for a failed save — a
    /// false alarm on the happiest turn in the mission.
    ///
    /// Pure, static and `nonisolated` so both sides of that split can be pinned without standing up
    /// a failed gather or hopping to the main actor.
    nonisolated static func dockMode(
        for interaction: MissionPendingInteraction,
        hasQueuedRetry: Bool
    ) -> MissionDockState.Mode {
        switch interaction.kind {
        case .recovery: return .recovery
        case .retry: return hasQueuedRetry ? .recovery : .confirmation
        case .clarification where interaction.options.contains(where: { $0.id == "stop" }): return .working
        case .clarification where interaction.options.isEmpty: return .freeText
        default: return interaction.selectionMode == .confirmation ? .confirmation : .singleChoice
        }
    }

    /// The composer placeholder is the free-text affordance's teacher: each question names what
    /// typing can do right now, instead of a generic "Message Crumb…".
    private func dockPlaceholder(for interaction: MissionPendingInteraction) -> String {
        guard interaction.allowsFreeText else { return "Choose a response" }
        switch interaction.kind {
        case .productDecision:
            return isSingleProductMission
                ? "Shortlist it, skip it, or ask for a change…"
                : "Add it, skip it, or ask for a change…"
        case .cartReview: return "Or say what to change…"
        case .refinement: return "Tell me what to adjust…"
        case .retry: return "Or tell me what to change…"
        case .clarification:
            if case .clarification(let context) = interaction.resolver,
               context == "working:gathering" {
                return "Toss in tweaks while I search…"
            }
            return "Message Crumb…"
        default: return "Message Crumb…"
        }
    }

    /// Convenience entry points for the response dock. They capture the current frozen identity;
    /// external callers that may be delayed (App Intents) submit a fully populated value instead.
    func submitMissionOption(_ optionID: String) {
        if optionID == "save-again" { retryThreadPersistence(); return }
        if optionID == "discard" { discardUnsavedThreadChanges(); return }
        guard let thread = activeThread, let interaction = thread.pendingInteraction else { return }
        submitMissionAnswer(MissionInteractionSubmission(
            threadID: thread.id, interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision,
            answer: .option(id: optionID)
        ))
    }

    func submitMissionText(_ text: String) {
        guard let thread = activeThread, let interaction = thread.pendingInteraction else { return }
        submitMissionAnswer(MissionInteractionSubmission(
            threadID: thread.id, interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision,
            answer: .freeText(text)
        ))
    }

    func productInteractionSubmission(
        productID: Product.ID,
        optionID: String,
        expectedThreadID: String? = nil,
        expectedInteractionID: String? = nil,
        expectedGeneration: Int? = nil,
        expectedSubjectRevision: Int? = nil,
        expectedVariantID: Variant.ID? = nil
    ) -> MissionInteractionSubmission? {
        guard let thread = activeThread, let interaction = thread.pendingInteraction,
              thread.blockingRecovery == nil,
              case .product(let currentID, let currentVariantID) = interaction.resolver,
              currentID == productID,
              interaction.options.contains(where: { $0.id == optionID }) else { return nil }
        if let expectedThreadID, expectedThreadID != thread.id { return nil }
        if let expectedInteractionID, expectedInteractionID != interaction.id { return nil }
        if let expectedGeneration, expectedGeneration != interaction.interactionGeneration { return nil }
        if let expectedSubjectRevision, expectedSubjectRevision != interaction.subjectRevision { return nil }
        if let expectedVariantID, expectedVariantID != currentVariantID { return nil }
        return MissionInteractionSubmission(
            threadID: thread.id, interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision,
            answer: .option(id: optionID)
        )
    }

    /// Answers a Home row's frozen question without opening the mission first.
    ///
    /// Home used to have exactly one verb — *go to the mission* — so it told you a decision was needed
    /// and then sent you elsewhere to make it. That is a notification list rather than an inbox. The
    /// question and its options are already frozen on the thread, and `MissionThread.validate(_:)` is a
    /// pure check that never asks whether the thread is active, so the only thing standing in the way
    /// was that `submitMissionAnswer` reads `activeThread`.
    ///
    /// Activation deliberately does NOT go through `resumeThread`: that supersedes the pending
    /// interaction and installs a fresh retry question, which would discard the very question being
    /// answered. `installActiveThread` sets the thread without touching its interaction.
    ///
    /// Navigation is left to the existing effects. Approving a plan still routes into the mission
    /// because curation does that; a retry keeps you on Home and the row flips to "Crumb is working".
    @discardableResult
    func answerFromHome(_ thread: MissionThread, optionID: String) -> MissionSubmissionResult {
        guard let interaction = thread.pendingInteraction,
              thread.blockingRecovery == nil,
              interaction.options.contains(where: { $0.id == optionID }) else { return .rejected }

        // In-flight tasks belong to whichever thread was active. Leaving them running while a
        // different thread becomes active would let their continuations mutate the wrong aggregate
        // through `mutateActiveThread`. `resumeThread` cancels for the same reason, so opening a
        // mission from Home already has this effect — answering from Home is not new exposure.
        cancelOperations()
        // The thread came from the store or from memory, so it is already durable; re-persisting an
        // unchanged aggregate here would just add a write before the answer's own transaction.
        installActiveThread(thread, persist: false)
        guard activeThread?.id == thread.id else { return .rejected }

        return submitMissionAnswer(
            MissionInteractionSubmission(
                threadID: thread.id,
                interactionID: interaction.id,
                interactionGeneration: interaction.interactionGeneration,
                subjectRevision: interaction.subjectRevision,
                answer: .option(id: optionID)
            )
        )
    }

    @discardableResult
    func submitMissionAnswer(_ submission: MissionInteractionSubmission) -> MissionSubmissionResult {
        guard var thread = activeThread else { return .rejected }
        let interaction: MissionPendingInteraction
        do { interaction = try thread.validate(submission) }
        catch {
            return .rejected
        }

        let displayAnswer: String
        // A tapped chip and a typed sentence become the same `.userMessage`, so the id of the chosen
        // option rides along to tell them apart later. Only prose is irreplaceable.
        let chosenOptionID: String?
        switch submission.answer {
        case .option(let id):
            displayAnswer = interaction.options.first(where: { $0.id == id })?.label ?? id
            chosenOptionID = id
        case .freeText(let text):
            displayAnswer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            chosenOptionID = nil
        }

        do { try thread.resolveInteraction(submission) }
        catch { return .rejected }
        thread.revision += 1
        thread.updatedAt = clock()
        thread.appendEvent(
            kind: .userMessage, text: displayAnswer, createdAt: clock(),
            operationID: submission.idempotencyID, chosenOptionID: chosenOptionID
        )

        var effect: MissionReducerEffect?
        interactionConstructionFailure = nil
        reduceResolvedAnswer(submission, interaction: interaction, thread: &thread, effect: &effect)
        if let failure = interactionConstructionFailure {
            threadPersistenceWarning = "This conversation couldn't continue safely: \(failure)"
            interactionConstructionFailure = nil
            return .rejected
        }
        if let effect { queue(effect, submissionID: submission.idempotencyID, in: &thread) }
        activeThread = thread
        upsertThreadInMemory(thread)
        guard persistThread(thread, committedID: submission.idempotencyID) else { return .unsaved }
        runMissionEffect(effect)
        return .applied
    }

    private enum MissionReducerEffect {
        case beginCuration
        case replaceGoal(String)
        case changePlan(String)
        case refine(String)
        case retry(MissionRetryDescriptor)
        case saveTaste
        case openCart
        /// Start paying: prepare a UCP checkout session per shop in the kit. Distinct from
        /// ``openCart`` because looking at a cart and paying for one are different requests, and
        /// answering one with the other is how this loop used to strand people.
        case startCheckout
        /// A terminal answer: the mission is over and we leave for Home. Distinct from plain
        /// navigation because ending is also a **save trigger** — see ``runMissionEffect(_:)``.
        case endMission
    }

    private func runMissionEffect(_ effect: MissionReducerEffect?) {
        guard let effect else { return }
        switch effect {
        case .beginCuration: startCurating()
        case .replaceGoal(let text):
            Task { @MainActor [weak self] in await self?.retryPlanningInActiveThread(goal: text, appendUserEvent: false) }
        case .changePlan(let text):
            Task { @MainActor [weak self] in await self?.applyPlanChange(text: text) }
        case .refine(let text):
            launchedOperationTasks[.refinement]?.cancel()
            launchedOperationTasks[.refinement] = Task { @MainActor [weak self] in
                await self?.applyRefinement(text: text, appendUserEvent: false)
            }
        case .retry(let retry): runRetry(retry)
        case .saveTaste: Task { @MainActor [weak self] in await self?.performQueuedTasteSave() }
        case .openCart: openCart()
        case .startCheckout:
            // Opening the cart first is deliberate: the checkout sheet is presented over it, so
            // dismissing payment lands on the kit rather than dumping the person back into the
            // mission with no idea whether anything was kept.
            openCart()
            Task { @MainActor [weak self] in await self?.startCheckoutWorkflow() }
        case .endMission:
            // Ending is the *other* save trigger. Reaching the cart used to be the only one, so a
            // kit assembled and then ended — never opened — left Home (its phase is terminal, so
            // `upsertThreadInMemory` drops it) without ever reaching History, and no screen reads
            // `threadStore` for finished missions. The kit became unreachable from every surface.
            // `recordCurrentKit` no-ops when nothing was kept, so ending an empty mission still
            // records nothing, and it upserts, so a cart→back→end round-trip stays one entry.
            recordKitToHistory()
            goToMissions()
        }
    }

    /// Records the accepted answer's continuation before the answer is considered durable. The
    /// concrete worker may replace this descriptor with its own operation id, but a crash or failed
    /// save can always recover/retry the accepted action without asking the prior question again.
    private func queue(_ effect: MissionReducerEffect, submissionID: String, in thread: inout MissionThread) {
        let retry: MissionRetryDescriptor?
        let title: String
        switch effect {
        case .beginCuration:
            retry = MissionRetryDescriptor(kind: .gathering, input: thread.task?.searchQueries.joined(separator: "\n") ?? "", taskRevision: thread.revision, returnPhase: .planReady)
            title = "Searching the shops…"
            thread.phase = .gathering
        case .replaceGoal(let goal):
            retry = MissionRetryDescriptor(kind: .planning, input: goal, taskRevision: nil, returnPhase: .planning)
            title = "Starting your mission…"
            thread.phase = .planning
        case .changePlan(let change):
            retry = MissionRetryDescriptor(kind: .planning, input: change, taskRevision: thread.revision, returnPhase: .planReady)
            title = "Updating the plan…"
            thread.phase = .planning
        case .refine(let text):
            retry = MissionRetryDescriptor(kind: .refinement, input: text, taskRevision: thread.revision, returnPhase: .deckReady)
            title = "Reworking the picks…"
        case .retry(let descriptor):
            retry = descriptor
            // A resumed/retried gather is just the search again — say so, rather than showing
            // generic retry copy on a seed mission's very first search.
            title = descriptor.kind == .gathering ? "Searching the shops…" : "Trying that turn again…"
        case .saveTaste:
            retry = MissionRetryDescriptor(kind: .chips, input: "save-to-taste", taskRevision: thread.revision, returnPhase: .deckReady)
            title = "Saving this to taste…"
        case .openCart, .startCheckout, .endMission:
            retry = nil
            title = ""
        }
        guard let retry else { return }
        let operationID = "answer-\(submissionID)"
        thread.pendingOperation = MissionPendingOperation(id: operationID, retry: retry, startedAt: clock())
        thread.retry = nil
        installWorkingQuestion(in: &thread, operationID: operationID, title: title, context: retry.kind.rawValue)
    }

    private func runQueuedRetry(_ retry: MissionRetryDescriptor) {
        switch retry.kind {
        case .planning where retry.returnPhase == .planning:
            Task { @MainActor [weak self] in await self?.retryPlanningInActiveThread(goal: retry.input, appendUserEvent: false) }
        case .planning:
            Task { @MainActor [weak self] in await self?.applyPlanChange(text: retry.input) }
        case .gathering, .curation:
            startCurating()
        case .refinement:
            launchedOperationTasks[.refinement] = Task { @MainActor [weak self] in
                await self?.applyRefinement(text: retry.input, appendUserEvent: false)
            }
        case .chips where retry.input == "save-to-taste":
            Task { @MainActor [weak self] in await self?.performQueuedTasteSave() }
        case .chips:
            if let task = selectedTask { refreshRefineChips(for: task) }
        }
    }

    private func reduceResolvedAnswer(
        _ submission: MissionInteractionSubmission,
        interaction: MissionPendingInteraction,
        thread: inout MissionThread,
        effect: inout MissionReducerEffect?
    ) {
        let option: String? = { if case .option(let id) = submission.answer { return id }; return nil }()
        let text: String? = { if case .freeText(let value) = submission.answer { return value.trimmed }; return nil }()

        switch interaction.resolver {
        case .plan:
            // Legacy only: nothing installs a plan-approval turn anymore, but a thread persisted
            // before direct missions may resume with one — honor its answers rather than strand it.
            if option == "start-shopping" { effect = .beginCuration }
            else if option == "start-over" {
                thread.phase = .abandoned
                thread.appendEvent(kind: .notice, text: "Ended this mission.", createdAt: clock())
                effect = .endMission
            } else if let text { effect = .changePlan(text) }
            else { installPlanChangeQuestion(in: &thread) }

        case .product(let productID, let variantID):
            guard let product = thread.candidates.first(where: { $0.id == productID }),
                  thread.remainingDeckIDs.contains(productID) else {
                installNextProductOrKitQuestion(in: &thread)
                return
            }
            // A typed answer that matches the question's own vocabulary IS the answer — it carries
            // the same frozen product identity as the chip, so it acts immediately instead of
            // detouring through a confirmation turn. Prose can now also carry a *next step* in the
            // same breath ("I like it. Let's create a cart."); the decision is applied here and
            // `nextStep` is honored below, after the write has landed.
            let utterance = text.map(MissionUtterance.parse)
            let choice = option ?? utterance?.decision.map(Self.optionID(for:))
            // When the same message also says where to go, `applyNextStep` installs the question
            // that lands there. Installing the *next product* question first would append an
            // assistant turn nobody asked for and immediately supersede it.
            let goesElsewhere = utterance?.nextStep != nil
            switch choice {
            case "add":
                guard let variantID,
                      let variant = product.variants.first(where: { $0.id == variantID }),
                      let snapshot = productSnapshot(for: interaction, productID: productID, in: thread),
                      snapshot.productID == product.id,
                      snapshot.variantID == variant.id,
                      snapshot.title == product.name,
                      snapshot.merchant == product.shop.name,
                      snapshot.presentedPrice == variant.price else {
                    thread.appendEvent(
                        kind: .assistantMessage,
                        text: "That pick changed since I showed it, so I refreshed the details before adding it.",
                        createdAt: clock(), productID: product.id
                    )
                    installProductQuestion(in: &thread, product: product)
                    return
                }
                if !thread.kit.contains(where: { $0.product.id == productID }) {
                    thread.kit.append(KitItem(product: product, variant: variant))
                    thread.remainingDeckIDs.removeAll { $0 == productID }
                    thread.decisions.append(MissionProductDecision(
                        id: submission.idempotencyID, kind: .added, productID: productID,
                        variantID: variant.id, createdAt: clock()
                    ))
                    thread.appendEvent(kind: .productAdded, text: "Added \(product.name).", createdAt: clock(), productID: productID, operationID: submission.idempotencyID)
                }
                if !goesElsewhere { installNextProductOrKitQuestion(in: &thread) }
            case "skip":
                thread.remainingDeckIDs.removeAll { $0 == productID }
                thread.decisions.append(MissionProductDecision(id: submission.idempotencyID, kind: .skipped, productID: productID, createdAt: clock()))
                thread.appendEvent(kind: .productSkipped, text: "Skipped \(product.name).", createdAt: clock(), productID: productID, operationID: submission.idempotencyID)
                if !goesElsewhere { installNextProductOrKitQuestion(in: &thread) }
            case "show-another":
                thread.remainingDeckIDs.removeAll { $0 == productID }
                thread.remainingDeckIDs.append(productID)
                thread.appendEvent(kind: .notice, text: "Showing another option.", createdAt: clock(), productID: productID)
                installNextProductOrKitQuestion(in: &thread)
            case let choice? where choice.hasPrefix("foil:"):
                // Promote the chosen alternative to the recommendation and ask again, so it gets
                // its own card and its own reason. A tap on a price is a look, not a purchase.
                let foilID = String(choice.dropFirst("foil:".count))
                guard let foil = thread.candidates.first(where: { $0.id == foilID }),
                      thread.remainingDeckIDs.contains(foilID) else {
                    installNextProductOrKitQuestion(in: &thread)
                    return
                }
                thread.remainingDeckIDs.removeAll { $0 == foilID }
                thread.remainingDeckIDs.insert(foilID, at: 0)
                thread.phase = .deckReady
                installProductQuestion(in: &thread, product: foil)
            // Legacy: persisted threads may still carry an "Adjust search" option.
            case "adjust-search": installRefinementQuestion(in: &thread)
            case "reset":
                resetRefinements(in: &thread)
                installNextProductOrKitQuestion(in: &thread)
            case "save-to-taste":
                effect = .saveTaste
            default:
                // Nothing in the message decided anything about *this* product. If it asked to go
                // somewhere, honor that below; otherwise it is a change request, as before.
                if utterance?.nextStep == nil, let refinement = utterance?.refinement {
                    effect = .refine(refinement)
                } else if utterance?.nextStep == nil {
                    installNextProductOrKitQuestion(in: &thread)
                }
            }
            if let utterance {
                applyNextStep(utterance, in: &thread, effect: &effect)
            }

        case .kit:
            switch option {
            case "review-cart":
                installKitQuestion(in: &thread)
                effect = .openCart
            case "find-more":
                let kept = Set(thread.kit.map { $0.product.id })
                thread.decisions.removeAll { $0.kind == .skipped }
                thread.remainingDeckIDs = thread.candidates.map(\.id).filter { !kept.contains($0) }
                installNextProductOrKitQuestion(in: &thread)
            case "checkout":
                effect = .startCheckout
            case "end":
                thread.phase = .completed
                thread.appendEvent(kind: .notice, text: "Ended this mission.", createdAt: clock())
                effect = .endMission
            default:
                // "Check out" typed at the kit question means the same thing as tapping it.
                let utterance = text.map(MissionUtterance.parse)
                if let utterance, utterance.nextStep != nil {
                    applyNextStep(utterance, in: &thread, effect: &effect)
                } else if let refinement = utterance?.refinement {
                    effect = .refine(refinement)
                } else {
                    installNextProductOrKitQuestion(in: &thread)
                }
            }

        case .retry(let retry):
            if option == "retry" { effect = .retry(retry) }
            else if option == "cancel" {
                thread.retry = nil
                thread.phase = .abandoned
                thread.appendEvent(kind: .notice, text: "Ended this mission.", createdAt: clock())
                effect = .endMission
            }
            else if let text {
                switch retry.kind {
                case .planning where retry.returnPhase == .planning: effect = .replaceGoal(text)
                case .planning, .gathering, .curation: effect = .changePlan(text)
                case .refinement: effect = .refine(text)
                case .chips: installQuestionForStableState(in: &thread)
                }
            }

        case .refinement:
            if option == "reset" { resetRefinements(in: &thread); installNextProductOrKitQuestion(in: &thread) }
            else if option == "save-to-taste" { effect = .saveTaste; installNextProductOrKitQuestion(in: &thread) }
            else if let text { effect = .refine(text) }
            else { installNextProductOrKitQuestion(in: &thread) }

        case .clarification(let context):
            if option == "cancel" {
                cancelOperations()
                thread.pendingOperation = nil
                thread.retry = nil
                thread.phase = .abandoned
                thread.appendEvent(kind: .notice, text: "Ended this mission.", createdAt: clock())
                effect = .endMission
            } else if option == "stop" {
                cancelOperations()
                thread.pendingOperation = nil
                thread.retry = nil
                thread.phase = thread.task == nil ? .declined : (thread.candidates.isEmpty ? .planReady : .deckReady)
                // The stopped gather leaves the load flag mid-flight; settle it so the composer
                // and the resume question tell one story.
                loadState = thread.candidates.isEmpty ? .idle : .loaded
                thread.appendEvent(kind: .notice, text: "Stopped that work.", createdAt: clock())
                // Stop halts everything, including text queued for the settle that now won't
                // come — dropping it silently would break the "I'll fold it in" promise, and
                // draining it later (a retry weeks on) would apply a forgotten constraint.
                if let queued = thread.queuedRefinements, !queued.isEmpty {
                    thread.queuedRefinements = nil
                    thread.appendEvent(
                        kind: .notice,
                        text: "I set aside \u{201C}\(queued.joined(separator: ". "))\u{201D} — send it again whenever you want it applied.",
                        createdAt: clock()
                    )
                }
                installQuestionForStableState(in: &thread)
            } else if context == "declined", let text { effect = .replaceGoal(text) }
            else if context == "plan-change", let text { effect = .changePlan(text) }
            else if context == "working:gathering", let text, thread.task != nil {
                // Mid-search free text must not cancel the gather — and on an empty deck it used
                // to queue a "Reworking the picks…" turn that could never run (the refinement
                // bails without candidates), wedging the thread. Hold the text instead and apply
                // it as a refinement the moment the deck settles (see `loadCandidates`).
                thread.queuedRefinements = (thread.queuedRefinements ?? []) + [text]
                installQueuedRefinementNotice(in: &thread, text: text)
            }
            else if context.hasPrefix("working:"), let text {
                cancelOperations()
                thread.pendingOperation = nil
                effect = thread.task == nil ? .replaceGoal(text) : .refine(text)
            }
        }
    }

    private func runRetry(_ retry: MissionRetryDescriptor) {
        switch retry.kind {
        case .planning: Task { @MainActor [weak self] in await self?.retryPlanningInActiveThread(goal: retry.input, appendUserEvent: false) }
        case .gathering, .curation:
            // Through beginCuration (not a bare loadCandidates) so a resume re-commits the shell
            // exactly like the original chain — one path whether shopping starts, retries, or resumes.
            if selectedTask != nil { startCurating() }
        case .refinement: Task { @MainActor [weak self] in await self?.applyRefinement(text: retry.input, appendUserEvent: false) }
        case .chips where retry.input == "save-to-taste":
            Task { @MainActor [weak self] in await self?.performQueuedTasteSave() }
        case .chips: if let task = selectedTask { refreshRefineChips(for: task) }
        }
    }

    /// Interaction construction is an application invariant, not a best-effort enhancement. A
    /// malformed resolver must fail loudly in development and can never leave a write-capable UI
    /// silently detached from its durable question.
    private func requireInteraction(_ install: () throws -> Void) {
        do { try install() }
        catch {
            interactionConstructionFailure = String(describing: error)
        }
    }

    private func installWorkingQuestion(
        in thread: inout MissionThread,
        operationID: String,
        title: String,
        context: String
    ) {
        // Answering a question can queue this same working state synchronously (`queue(_:)`)
        // before the worker runs. One live working turn per chain: if the identical question is
        // already current, keep it instead of stacking a second matching pill in the feed.
        if let pending = thread.pendingInteraction,
           case .clarification(let existing) = pending.resolver,
           existing == "working:\(context)",
           pending.question == title {
            return
        }
        thread.supersedePendingInteraction()
        // The activity receipt is the sole in-feed narration for this working turn; repeating the
        // title as message text stacked the same string twice in a row (three times counting the
        // gathering marker event).
        thread.appendEvent(
            kind: .assistantMessage,
            text: "",
            createdAt: clock(),
            operationID: operationID,
            blocks: [.activity(MissionActivityReceipt(operationID: operationID, title: title))]
        )
        guard let promptID = thread.timeline.last?.id else { return }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID,
            subjectRevision: thread.revision,
            kind: .clarification,
            question: title,
            options: [MissionInteractionOption(id: "stop", label: "Stop")],
            allowsFreeText: true,
            resolver: .clarification(contextID: "working:\(context)"),
            createdAt: clock()
            )
        }
    }

    /// The in-thread notice for a mission that kept a real multi-part plan (the deterministic
    /// kit expansions — e.g. the lacrosse safety/fit kit and its stated assumption). A read-only
    /// timeline attachment the user can talk back to, **never** a blocking approval turn: the
    /// search starts immediately, and free text (mid-search or after) reworks the picks or the
    /// goal. One-part shells stay notice-free — the deck is the first artifact they see.
    private func installKitPlanNotice(in thread: inout MissionThread, task: ShoppingTask) {
        guard thread.plan.count > 1 else { return }
        let snapshot = MissionPlanSnapshot(
            id: "plan-\(thread.id)-\(thread.revision)", revision: thread.revision,
            title: task.title, parts: thread.plan
        )
        thread.appendEvent(
            kind: .planReady,
            text: task.curatorNote,
            createdAt: clock(),
            blocks: [.plan(snapshot)]
        )
    }

    /// The direct-mode replacement for the old plan-approval turn on a shell that hasn't gathered
    /// yet (a stopped search, a recovered interruption, a fresh seed mission): a lightweight
    /// confirmation whose accept re-runs the shopping chain (``beginCuration()`` via the retry
    /// resolver) — never a blocking plan review.
    private func installResumeShoppingQuestion(
        in thread: inout MissionThread,
        question: String = "Want me to pick the search back up?",
        actionLabel: String = "Resume shopping"
    ) {
        // Same guard shape as the plan-approval question this replaces: a planless shell (the
        // test fixtures' kit-container threads) has nothing to resume, and installing a question
        // there would block the legacy direct add/skip paths.
        guard let task = thread.task, !thread.plan.isEmpty else { return }
        thread.supersedePendingInteraction()
        thread.appendEvent(kind: .assistantMessage, text: question, createdAt: clock())
        guard let promptID = thread.timeline.last?.id else { return }
        let retry = MissionRetryDescriptor(
            kind: .gathering,
            input: task.searchQueries.joined(separator: "\n"),
            taskRevision: thread.revision,
            returnPhase: .planReady
        )
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID,
            subjectRevision: thread.revision,
            kind: .retry,
            question: question,
            options: [
                MissionInteractionOption(id: "retry", label: actionLabel),
                MissionInteractionOption(id: "cancel", label: "End mission", isDestructive: true),
            ],
            allowsFreeText: true,
            resolver: .retry(retry),
            createdAt: clock()
            )
        }
    }

    /// Acknowledges free text typed while the gather is still searching: the text was queued
    /// (see ``MissionThread/queuedRefinements``) and the search keeps running, so this re-arms
    /// the same working-style question (Stop + free text) the answer just resolved.
    private func installQueuedRefinementNotice(in thread: inout MissionThread, text: String) {
        thread.appendEvent(
            kind: .assistantMessage,
            text: "Got it — I’ll fold \u{201C}\(text)\u{201D} in as soon as the picks land.",
            createdAt: clock()
        )
        guard let promptID = thread.timeline.last?.id else { return }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .clarification, question: "Searching the shops…",
            options: [MissionInteractionOption(id: "stop", label: "Stop")],
            allowsFreeText: true,
            resolver: .clarification(contextID: "working:gathering"),
            createdAt: clock()
            )
        }
    }

    private func installPlanChangeQuestion(in thread: inout MissionThread) {
        thread.appendEvent(kind: .assistantMessage, text: "What should I change in the plan?", createdAt: clock())
        guard let promptID = thread.timeline.last?.id else { return }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .clarification, question: "What should I change in the plan?",
            options: [], allowsFreeText: true,
            resolver: .clarification(contextID: "plan-change"), createdAt: clock()
            )
        }
    }

    private func installDeclinedQuestion(in thread: inout MissionThread) {
        thread.supersedePendingInteraction()
        thread.appendEvent(kind: .assistantMessage, text: "What would you like to shop for instead?", createdAt: clock())
        guard let promptID = thread.timeline.last?.id else { return }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .clarification, question: "What would you like to shop for instead?",
            options: [MissionInteractionOption(id: "cancel", label: "Cancel")],
            allowsFreeText: true, resolver: .clarification(contextID: "declined"), createdAt: clock()
            )
        }
    }

    private func installProductQuestion(
        in thread: inout MissionThread,
        product: Product,
        includeRefinementFollowUps: Bool = false
    ) {
        thread.supersedePendingInteraction()
        let variant = product.defaultVariant
        // Crumb answers with one pick and the two options that make it legible — what you'd give
        // up spending less, what you'd get spending more. The reported session offered five
        // near-identical teas on a price ladder with no photo and no reason, which is the job of
        // deciding handed straight back to the person who asked Crumb to decide.
        let foils = Self.foils(for: product, in: thread)
        let block: MissionMessageBlock
        if foils.isEmpty {
            block = .product(MissionProductSnapshot(product: product, variant: variant))
        } else {
            block = .comparison(MissionComparisonSnapshot(
                id: "compare-\(thread.id)-\(thread.revision)-\(product.id)",
                products: ([product] + foils).map {
                    MissionProductSnapshot(product: $0, variant: $0.defaultVariant)
                }
            ))
        }
        thread.appendEvent(
            kind: .assistantMessage,
            // The prompt sits *after* its artifact (see `placesQuestionAfterArtifacts`), so this has
            // to read as a closing line, not a lead-in.
            text: foils.isEmpty ? "How does this one look?" : "That's the one I'd get.",
            createdAt: clock(), productID: product.id,
            blocks: [block]
        )
        guard let promptID = thread.timeline.last?.id else { return }
        // The interaction contract caps a question at four options, so the slots are spent in
        // order of what a person needs: act on the pick, reject the pick, the one time-sensitive
        // follow-up, then the alternatives.
        var options = [
            MissionInteractionOption(
                id: "add",
                label: isSingleProductMission ? "Shortlist" : "Add to cart",
                detail: variant.price.formatted(.currency(code: "USD"))
            ),
            MissionInteractionOption(id: "skip", label: "Skip"),
        ]
        // Right after a refinement lands, one contextual follow-up rides the next question — the
        // moment it's alive. Save-to-taste when the directive can be kept, else Reset as the undo.
        if includeRefinementFollowUps {
            if thread.refinementDirectives.contains(where: { $0.isActionable }) {
                options.append(MissionInteractionOption(id: "save-to-taste", label: saveToTasteChipLabel))
            } else if !thread.refinementTurns.isEmpty {
                options.append(MissionInteractionOption(id: "reset", label: "Reset changes"))
            }
        }
        if foils.isEmpty {
            options.append(MissionInteractionOption(id: "show-another", label: "Show another"))
        } else {
            // The alternatives are named with their prices rather than hidden behind a generic
            // "Show alternatives": same affordance, one tap shorter, and it says what it costs.
            // Choosing one promotes it to the recommendation and re-asks, so nothing is bought by
            // a tap that a person meant as a look.
            //
            // "Show another" retires here — the foils *are* the other options, shown rather than
            // promised. A contextual follow-up displaces the second foil rather than the first,
            // because a cheaper option is the alternative people reach for most.
            for foil in foils.prefix(max(0, 4 - options.count)) {
                options.append(MissionInteractionOption(
                    id: "foil:\(foil.id)",
                    label: foil.price < product.price ? "Cheaper" : "Nicer",
                    detail: foil.defaultVariant.price.formatted(.currency(code: "USD"))
                ))
            }
        }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .productDecision, question: "What should I do with \(product.name)?",
            options: options,
            allowsFreeText: true,
            resolver: .product(productID: product.id, variantID: variant.id),
            createdAt: clock()
            )
        }
    }

    /// The two options worth showing beside `product`, drawn from what is still undecided.
    ///
    /// The ranking is the curator's — model-produced, and that is where taste belongs.
    /// ``MissionShortlist`` only enforces the floors a ranking model gets wrong expensively:
    /// duplicates, foils too close in price to be a real choice, and outliers.
    /// Only a single-item mission has foils, because only there is the deck an apples-to-apples set.
    ///
    /// A kit mission's candidates are the **union of every part's search**, with no record of which
    /// part found what — the gather is model-driven and its tool hands back bare products. So on
    /// "Set up my pour-over corner" the products next to the beans are the brew mat and the
    /// kettle: other *parts*, not alternatives. Offering them as "Costs less" and "A step up"
    /// would be worse than the price ladder this design replaces, because it would be confidently
    /// wrong. Restoring foils for kits needs part attribution at gather time.
    private static func foils(for product: Product, in thread: MissionThread) -> [Product] {
        guard thread.task?.isSingleItem == true else { return [] }
        // The winner leads, so the shortlist ranks from the product being asked about.
        let ordered = [product] + thread.remainingDeck.filter { $0.id != product.id }
        return MissionShortlist.choose(from: ordered)?.foils ?? []
    }

    /// Bridges a parsed decision to the option id the product question's own chips use, so a typed
    /// answer and a tapped chip take exactly one code path into the write.
    ///
    /// The vocabulary itself lives in ``MissionUtterance`` — pure, in the kit, and directly
    /// testable. It used to live here as a whole-string dictionary lookup, which is why
    /// "I like it. Let's create a cart." was read as a request to change the picks.
    static func optionID(for decision: MissionDecision) -> String {
        switch decision {
        case .add: return "add"
        case .skip: return "skip"
        case .showAnother: return "show-another"
        }
    }

    /// Honors the "…and then take me somewhere" half of a message, after its decision has landed.
    ///
    /// A next step outranks a leftover change request in the same message. Applying both would
    /// re-curate the deck immediately after the person asked to go look at their cart, which is a
    /// smaller version of the same bug this work exists to fix — so the leftover is named and set
    /// aside rather than silently run or silently dropped.
    private func applyNextStep(
        _ utterance: MissionUtterance,
        in thread: inout MissionThread,
        effect: inout MissionReducerEffect?
    ) {
        guard let nextStep = utterance.nextStep else { return }
        if let refinement = utterance.refinement {
            thread.appendEvent(
                kind: .notice,
                text: "I set aside \u{201C}\(refinement)\u{201D} — send it again whenever you want it applied.",
                createdAt: clock()
            )
        }
        guard !thread.kit.isEmpty else {
            // Asking for a cart with an empty kit is a reasonable thing to say and an impossible
            // thing to do. Say so, and leave the person on a question they can act on.
            thread.appendEvent(
                kind: .assistantMessage,
                text: "Nothing's in the cart yet — keep something first and I'll take you there.",
                createdAt: clock()
            )
            installNextProductOrKitQuestion(in: &thread)
            return
        }
        installKitQuestion(in: &thread)
        effect = nextStep == .checkout ? .startCheckout : .openCart
    }

    /// The frozen snapshot this question froze for `productID`.
    ///
    /// A pick question presents either one product or a recommendation beside its foils, so the
    /// snapshot may live in a `.product` block or inside a `.comparison`. It is matched **by
    /// product id** rather than taken as the first one found: in a comparison, "the first snapshot"
    /// is the recommendation, which is the wrong answer the moment someone chooses a foil.
    private func productSnapshot(
        for interaction: MissionPendingInteraction,
        productID: Product.ID,
        in thread: MissionThread
    ) -> MissionProductSnapshot? {
        let blocks = thread.timeline.first { $0.id == interaction.promptEventID }?.blocks ?? []
        for block in blocks {
            switch block {
            case .product(let snapshot) where snapshot.productID == productID:
                return snapshot
            case .comparison(let snapshot):
                if let match = snapshot.products.first(where: { $0.productID == productID }) {
                    return match
                }
            default:
                continue
            }
        }
        return nil
    }

    private func installKitQuestion(in thread: inout MissionThread) {
        thread.supersedePendingInteraction()
        let snapshot = MissionKitSnapshot(
            id: "kit-\(thread.id)-\(thread.revision)", revision: thread.revision,
            items: thread.kit.map(MissionKitSnapshotItem.init)
        )
        let question = thread.kit.isEmpty ? "Want me to look again?" : "Ready to check out?"
        thread.appendEvent(
            kind: .assistantMessage, text: question, createdAt: clock(), blocks: [.kit(snapshot)]
        )
        guard let promptID = thread.timeline.last?.id else { return }
        var options = [MissionInteractionOption(id: "find-more", label: "Find more")]
        if !thread.kit.isEmpty {
            // Checkout leads. A kit with nowhere to go is the whole reported failure: the only
            // offers here used to be "Find more" and "End mission", so a finished mission had no
            // button that moved it forward and free text was the only way out.
            options.insert(MissionInteractionOption(
                id: "checkout", label: "Check out", detail: kitSubtotalLabel(thread.kit)
            ), at: 0)
            options.insert(MissionInteractionOption(id: "review-cart", label: "Review cart"), at: 1)
        }
        options.append(MissionInteractionOption(id: "end", label: "End mission", isDestructive: true))
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .cartReview, question: question, options: options,
            allowsFreeText: true,
            resolver: .kit(snapshotID: snapshot.id, revision: snapshot.revision), createdAt: clock()
            )
        }
    }

    /// "$46.00" for the kit, as the Check out chip's detail line. Nil for an empty kit, which never
    /// offers the chip anyway.
    private func kitSubtotalLabel(_ kit: [KitItem]) -> String? {
        guard !kit.isEmpty else { return nil }
        let subtotal = kit.reduce(Decimal.zero) { $0 + $1.variant.price }
        return subtotal.formatted(.currency(code: "USD"))
    }

    private func installRefinementQuestion(in thread: inout MissionThread) {
        thread.supersedePendingInteraction()
        thread.appendEvent(kind: .assistantMessage, text: "What should I adjust?", createdAt: clock())
        guard let promptID = thread.timeline.last?.id else { return }
        var options: [MissionInteractionOption] = []
        if !thread.refinementTurns.isEmpty { options.append(MissionInteractionOption(id: "reset", label: "Reset changes")) }
        if thread.refinementDirectives.contains(where: { $0.isActionable }) {
            options.append(MissionInteractionOption(id: "save-to-taste", label: saveToTasteLabel))
        }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .refinement, question: "What should I adjust?", options: options,
            allowsFreeText: true, resolver: .refinement(baseRevision: thread.revision), createdAt: clock()
            )
        }
    }

    private func installRetryQuestion(in thread: inout MissionThread, retry: MissionRetryDescriptor) {
        thread.supersedePendingInteraction()
        thread.appendEvent(kind: .assistantMessage, text: "That turn didn’t finish. What next?", createdAt: clock())
        guard let promptID = thread.timeline.last?.id else { return }
        requireInteraction {
            try thread.installInteraction(
            promptEventID: promptID, subjectRevision: thread.revision,
            kind: .retry, question: "That turn didn’t finish. What next?",
            options: [
                MissionInteractionOption(id: "retry", label: "Retry"),
                // Reads as "cancel this turn", but the reducer abandons the whole mission — the
                // same branch "End mission" takes. Marking it destructive is what makes the
                // confirmation name the consequence the label doesn't.
                MissionInteractionOption(id: "cancel", label: "Cancel", isDestructive: true),
            ], allowsFreeText: true, resolver: .retry(retry), createdAt: clock()
            )
        }
    }

    private func installNextProductOrKitQuestion(
        in thread: inout MissionThread,
        includeRefinementFollowUps: Bool = false
    ) {
        let byID = Dictionary(uniqueKeysWithValues: thread.candidates.map { ($0.id, $0) })
        if let product = thread.remainingDeckIDs.compactMap({ byID[$0] }).first {
            thread.phase = .deckReady
            installProductQuestion(
                in: &thread, product: product,
                includeRefinementFollowUps: includeRefinementFollowUps
            )
        } else {
            // A useful final kit remains resumable and conversational until the person explicitly
            // chooses End; opening Cart is navigation, not terminal mission completion.
            thread.phase = .deckReady
            installKitQuestion(in: &thread)
        }
    }

    private func installQuestionForStableState(in thread: inout MissionThread) {
        switch thread.phase {
        case .planReady: installResumeShoppingQuestion(in: &thread)
        case .deckReady, .completed: installNextProductOrKitQuestion(in: &thread)
        case .declined: installDeclinedQuestion(in: &thread)
        case .failed:
            if let retry = thread.retry { installRetryQuestion(in: &thread, retry: retry) }
        default: break
        }
    }

    private func resetRefinements(in thread: inout MissionThread) {
        let excluded = Set(thread.kit.map { $0.product.id })
        thread.refinementTurns = []
        thread.refinementDirectives = []
        thread.candidates = thread.baseCandidates
        thread.remainingDeckIDs = thread.baseCandidates.map(\.id).filter { !excluded.contains($0) }
        thread.appendEvent(kind: .refinementsReset, text: "Reset the conversation changes.", createdAt: clock())
        refinementTier = nil
        canSaveRefinementToTaste = false
        isReworking = false
    }

    func sendThreadMessage(_ text: String) {
        if activeThread?.pendingInteraction != nil {
            submitMissionText(text)
            return
        }
        guard let phase = activeThread?.phase else { return }
        switch phase {
        case .declined:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.retryPlanningInActiveThread(goal: text)
            }
        case .deckReady:
            refine(text)
        default:
            break
        }
    }

    func resumeThread(_ thread: MissionThread) {
        cancelOperations()
        var recovered = thread
        do { try recovered.recoverAfterInterruption(at: clock()) }
        catch {
            threadLoadFailures.append(MissionThreadLoadFailure(id: thread.id, title: thread.goal, reason: String(describing: error)))
            return
        }
        if let retry = recovered.retry {
            recovered.revision += 1
            recovered.updatedAt = clock()
            recovered.supersedePendingInteraction()
            installRetryQuestion(in: &recovered, retry: retry)
        } else if recovered.pendingInteraction == nil {
            recovered.revision += 1
            recovered.updatedAt = clock()
            installQuestionForStableState(in: &recovered)
        }
        installActiveThread(recovered)
        planDecline = recovered.phase == .declined ? recovered.timeline.last?.text : nil
        planDirty = recovered.phase == .planReady
        loadState = recovered.phase == .deckReady ? .loaded : .idle
        canSaveRefinementToTaste = recovered.refinementDirectives.contains { $0.isActionable }
        if let task = recovered.task { refreshRefineChips(for: task) }
        route = .missionThread
    }

    func deleteThread(_ thread: MissionThread) {
        try? threadStore.delete(id: thread.id)
        incompleteThreads.removeAll { $0.id == thread.id }
        if activeThread?.id == thread.id {
            cancelOperations()
            activeThread = nil
            route = .missions
        }
    }

    func deleteThreadLoadFailure(_ failure: MissionThreadLoadFailure) {
        try? threadStore.delete(id: failure.id)
        threadLoadFailures.removeAll { $0.id == failure.id }
    }

    func retryThreadOperation() {
        if let interaction = activeThread?.pendingInteraction,
           interaction.options.contains(where: { $0.id == "retry" }) {
            submitMissionOption("retry")
            return
        }
        guard let retry = activeThread?.retry else { return }
        switch retry.kind {
        case .planning:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.retryPlanningInActiveThread(goal: retry.input)
            }
        case .gathering, .curation:
            guard selectedTask != nil else { return }
            startCurating()
        case .refinement:
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applyRefinement(text: retry.input)
            }
        case .chips:
            if let task = selectedTask { refreshRefineChips(for: task) }
        }
    }

    // MARK: Derived

    var missions: [ShoppingTask] { SeedData.missions }

    var currentCart: Cart { Cart(items: kit) }

    var accentHex: UInt32 { selectedTask?.accentHex ?? 0x1C4B43 }

    /// True when the current mission is a direct single-product search (e.g. `premium jasmine tea`)
    /// rather than a multi-part kit — the journey then frames Plan/Curate/Cart as shortlist-and-
    /// compare instead of kit assembly (#56). Derived from the planner's `isSingleItem` signal.
    var isSingleProductMission: Bool { selectedTask?.isSingleItem ?? false }

    /// The kit-completeness read for the current mission's cart, or `nil` when it doesn't apply — a
    /// single-product shortlist (#60) or a mission without a real multi-part checklist. Drives the
    /// Cart's readiness panel: for a complete-kit mission it says which plan categories the kit still
    /// misses before checkout, so a partial cart is never framed as a finished kit (#67).
    var kitCompleteness: KitCompleteness? {
        guard !isSingleProductMission, let plan = selectedTask?.plan else { return nil }
        let checklist = KitCompleteness.assess(plan: plan, items: currentCart.items.map(\.product))
        // Only a genuine multi-part kit gets a completeness panel; a one-item checklist isn't a "kit".
        guard checklist.requiredCount >= 2 else { return nil }
        return checklist
    }

    func isInKit(_ product: Product) -> Bool {
        kit.contains { $0.product.id == product.id }
    }

    private var excludedDeckProductIDs: Set<Product.ID> {
        Set(kit.map { $0.product.id }).union(
            activeThread?.decisions.filter { $0.kind == .skipped }.map(\.productID) ?? []
        )
    }

    // MARK: Navigation actions

    /// Selects a pre-built mission and routes to Plan, kicking off the "scanning shops" load
    /// immediately. The seed-mission path used by tests and the screenshot hooks; the live
    /// composer path goes through ``runPlan(goal:)`` → ``enterPlan(with:)`` instead, which
    /// defers the search until the user has edited the plan and tapped "Curate my kit".
    func select(_ task: ShoppingTask) {
        enterPlan(with: task)
        loadState = .loading
        planDirty = false
        let launched = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.loadCandidates(for: task)
        }
        launchedOperationTasks[.gathering] = launched
    }

    /// Re-runs the candidate load for the current mission (the Plan screen's "Retry").
    func retryLoad() {
        guard selectedTask != nil else { return }
        startCurating()
    }

    // MARK: Planning (free-text composer)

    /// Plans a typed goal in the background (the composer's "Plan it"). Fire-and-forget wrapper
    /// over ``runPlan(goal:)`` so the button stays synchronous; the async core is what tests
    /// drive deterministically.
    func planMission(goal: String, for recipient: Recipient? = nil) {
        cancelOperations()
        let launched = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.performPlan(goal: goal, for: recipient)
        }
        launchedOperationTasks[.planning] = launched
    }

    /// Decomposes `goal` via the injected ``MissionPlanner`` and either routes into an editable
    /// Plan (shoppable) or surfaces a friendly decline under the composer (not shoppable). A
    /// shoppable goal is also recorded in recents. Internal (not private) so tests can await it
    /// rather than racing the fire-and-forget `Task`.
    func runPlan(goal: String, for recipient: Recipient? = nil) async {
        cancelOperations()
        await performPlan(goal: goal, for: recipient)
    }

    private func performPlan(goal: String, for recipient: Recipient? = nil) async {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let profile = recipient?.taste ?? tasteProfile
        closeCheckoutWorkflow()
        curatorTier = nil
        refinementTier = nil
        canSaveRefinementToTaste = false
        isReworking = false
        isRecurating = false
        loadState = .idle
        settleWatchdog?.cancel()
        curationRefiningOvertime = false
        var thread = MissionThread(goal: trimmed, recipient: recipient, taste: profile, now: clock())
        thread.appendEvent(kind: .userMessage, text: trimmed, createdAt: clock())
        installActiveThread(thread)
        route = .missionThread
        await retryPlanningInActiveThread(goal: trimmed, appendUserEvent: false)
    }

    /// Runs (or retries) planning inside the current thread. Both thread and operation identity
    /// must still match when the model returns; cancellation alone is never trusted.
    private func retryPlanningInActiveThread(goal: String, appendUserEvent: Bool = true) async {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let threadID = activeThread?.id,
              let operationID = beginOperation(.planning) else { return }

        isPlanning = true
        planDecline = nil
        let retry = MissionRetryDescriptor(
            kind: .planning, input: trimmed, taskRevision: nil, returnPhase: .planning
        )
        mutateActiveThread {
            $0.goal = trimmed
            $0.phase = .planning
            $0.task = nil
            $0.plan = []
            $0.pendingOperation = MissionPendingOperation(id: operationID, retry: retry, startedAt: clock())
            $0.retry = nil
            if appendUserEvent {
                $0.appendEvent(kind: .userMessage, text: trimmed, createdAt: clock(), operationID: operationID)
            }
            $0.appendEvent(kind: .planningStarted, text: "Planning this mission…", createdAt: clock(), operationID: operationID)
            installWorkingQuestion(in: &$0, operationID: operationID, title: "Starting your mission…", context: "planning")
        }

        let profile = activeThread?.tasteSnapshot ?? tasteProfile
        let planned = await CrumbTrace.measure("plan", summarize: {
            "goalChars=\(trimmed.count) shoppable=\($0.task != nil) parts=\($0.task?.plan.count ?? 0) tier=\($0.tier.traceLabel)"
        }) {
            await planner.plan(goal: trimmed, profile: profile)
        }
        guard operationIsCurrent(.planning, id: operationID, threadID: threadID) else { return }
        isPlanning = false
        finishOperation(.planning, id: operationID)

        if let task = planned.task {
            recentsStore.addRecent(trimmed)
            recentGoals = recentsStore.loadRecents()
            plannerTier = planned.tier
            // Direct mission: no plan to review — commit the shell and go shopping. The
            // planning receipt (`pendingOperation`) deliberately survives this transaction so
            // every persisted intermediate state stays crash-recoverable (recovery re-offers
            // planning); `loadCandidates` replaces it with the gathering receipt in its own
            // transaction, and its working question supersedes the planning one. From here the
            // agentic orchestrator decides the catalog calls.
            mutateActiveThread {
                $0.task = task
                $0.plan = Self.draftParts(from: task)
                installKitPlanNotice(in: &$0, task: task)
            }
            planDirty = true
            // The direct chain keeps running inside the task launched under the planning
            // slot; hand the handle to the gathering slot so a retry's `startCurating()`
            // supersedes this in-flight chain instead of a long-finished planning turn. Only
            // when such a handle exists — re-plans that run *inside* the gathering slot (the
            // queued-refinement fold on an empty settle) must not nil out their own handle,
            // which would make the in-flight chain uncancellable.
            if let planningHandle = launchedOperationTasks.removeValue(forKey: .planning) {
                launchedOperationTasks[.gathering] = planningHandle
            }
            await beginCuration()
        } else {
            let decline = planned.decline ?? "I'm a shopping curator — hand me something to shop for."
            planDecline = decline
            mutateActiveThread {
                $0.phase = .declined
                $0.pendingOperation = nil
                $0.retry = retry
                $0.appendEvent(kind: .assistantMessage, text: decline, createdAt: clock(), operationID: operationID)
                installDeclinedQuestion(in: &$0)
            }
        }
    }

    /// Applies conversational plan feedback: with no upfront plan artifact to edit, the request is
    /// folded into the goal and the direct chain re-runs (which shops immediately). Kept as its own
    /// entry point because persisted retry descriptors (`kind: .planning, returnPhase: .planReady`)
    /// and pre-direct plan interactions still route here.
    private func applyPlanChange(text: String) async {
        let change = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !change.isEmpty, let goal = activeThread?.goal else { return }
        await retryPlanningInActiveThread(goal: "\(goal), \(change)", appendUserEvent: false)
    }

    /// Sets up the Plan screen for `task`: seeds the editable parts, resets the deck, and routes
    /// to Plan **without** searching yet (the search runs on "Curate my kit", after edits).
    func enterPlan(with task: ShoppingTask, recipient: Recipient? = nil) {
        cancelOperations()
        closeCheckoutWorkflow()
        let profile = recipient?.taste ?? tasteProfile
        var thread = MissionThread(goal: task.title, recipient: recipient, taste: profile, now: clock())
        thread.task = task
        thread.plan = Self.draftParts(from: task)
        thread.phase = .planReady
        thread.appendEvent(kind: .userMessage, text: task.title, createdAt: clock())
        installKitPlanNotice(in: &thread, task: task)
        installResumeShoppingQuestion(in: &thread, question: "Should I start shopping?", actionLabel: "Start shopping")
        installActiveThread(thread)
        curatorTier = nil
        refinementTier = nil
        canSaveRefinementToTaste = false
        isReworking = false
        loadState = .idle
        settleWatchdog?.cancel()
        curationRefiningOvertime = false
        planDirty = true
        route = .missionThread
    }

    /// Resets the ephemeral refinement conversation and its derived state — called whenever a new
    /// mission is entered (so refinements never leak across missions) and when a fresh deck is
    /// dealt. Does not touch the persisted ``TasteProfile``.
    private func clearRefinement() {
        mutateActiveThread {
            $0.refinementTurns = []
            $0.refinementDirectives = []
        }
        refinementTier = nil
        canSaveRefinementToTaste = false
        isReworking = false
    }

    /// Sets the Curate refine chips for `task`: the deterministic taxonomy floor immediately (so the
    /// bar renders the instant we route to Curate, and headless screenshots stay stable), then a
    /// best-effort on-device upgrade that replaces them in place when a model tier is up. The async
    /// pass no-ops if the user has already moved to another mission. See [[conversational-refinement]].
    private func refreshRefineChips(for task: ShoppingTask) {
        refineChips = RuleBasedRefineChipSuggester.chips(for: task)
        guard let threadID = activeThread?.id, let operationID = beginOperation(.chips) else { return }
        let profile = activeTaste
        let chipTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let suggested = await self.chipSuggester.chips(for: task, profile: profile)
            guard self.operationIsCurrent(.chips, id: operationID, threadID: threadID) else { return }
            refineChips = suggested
            self.finishOperation(.chips, id: operationID)
        }
        operationTasks[.chips] = chipTask
    }

    /// Builds editable parts from a task, pairing each plan label with its query by index and
    /// deriving a query from the label when the arrays don't line up (e.g. seed missions, whose
    /// labels and queries aren't 1:1).
    private static func draftParts(from task: ShoppingTask) -> [PlanPart] {
        task.plan.enumerated().map { index, label in
            let raw = index < task.searchQueries.count ? task.searchQueries[index] : label
            return PlanPart(label: label, query: RuleBasedMissionPlanner.clean(query: raw))
        }
    }

    // MARK: Plan editing

    /// Adds a new part to the draft plan (capped at ``RuleBasedMissionPlanner/maxParts``). Its
    /// query is derived from the label.
    func addPart(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, draftParts.count < RuleBasedMissionPlanner.maxParts else { return }
        mutateActiveThread {
            $0.plan.append(PlanPart(label: trimmed, query: RuleBasedMissionPlanner.clean(query: trimmed)))
            $0.phase = .planReady
        }
        planDirty = true
    }

    /// Removes a part from the draft plan.
    func removePart(_ part: PlanPart) {
        guard draftParts.count > 1 else { return }
        mutateActiveThread {
            $0.plan.removeAll { $0.id == part.id }
            $0.phase = .planReady
        }
        planDirty = true
    }

    /// Rewords a part's label and re-derives its query, so a reworded part re-runs against a
    /// query that matches the new wording when the user next curates.
    func updatePart(_ part: PlanPart, label: String) {
        guard let index = draftParts.firstIndex(where: { $0.id == part.id }) else { return }
        mutateActiveThread {
            guard $0.plan.indices.contains(index) else { return }
            $0.plan[index].label = label
            $0.plan[index].query = RuleBasedMissionPlanner.clean(query: label)
            $0.phase = .planReady
        }
        planDirty = true
    }

    /// Advances from Plan to the swipe deck, committing any plan edits and (re-)running the
    /// catalog search first. Fire-and-forget wrapper over ``beginCuration()``.
    func startCurating() {
        launchedOperationTasks[.gathering]?.cancel()
        let launched = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.beginCuration()
        }
        launchedOperationTasks[.gathering] = launched
    }

    /// Commits the edited plan into the mission's queries and loads candidates, then advances
    /// to Curate on success (staying on Plan to show the scanning / failed state otherwise). A
    /// clean, already-loaded plan (e.g. returning from Curate without edits) skips the reload.
    func beginCuration() async {
        guard let base = selectedTask else { return }
        // Reuse the loaded deck only when nothing is *waiting* on this run: a queued answer
        // (retry/resume) installs a pending operation + working question that only a real
        // reload clears — early-returning under one would wedge the thread on a spinner
        // question with nothing running (the crash-recovered-retry case).
        if !planDirty, loadState == .loaded, !candidates.isEmpty, activeThread?.pendingOperation == nil {
            route = .missionThread
            return
        }
        let queries = draftParts.map(\.query).filter { !$0.isEmpty }
        guard !queries.isEmpty else { return }   // nothing searchable — CTA is disabled anyway
        let task = base.rebuilt(plan: draftParts.map(\.label), searchQueries: queries)
        mutateActiveThread {
            $0.task = task
        }
        planDirty = false
        await loadCandidates(for: task)
        if loadState == .loaded { route = .missionThread }
    }

    #if DEBUG
    /// Screenshot/UITest hook: deterministically deal a mission's curated deck and land on
    /// Curate, bypassing onboarding and the Plan step. `simctl` can't tap, so headless deep
    /// screens are reached this way (driven by `CRUMB_SCREENSHOT` in `CrumbApp`/`RootView`).
    func presentCurateForScreenshot(missionID: String) async {
        var task = missions.first { $0.id == missionID } ?? SeedData.hike
        // `CRUMB_SINGLE=1` flips a seed mission into single-product framing so the shortlist copy
        // (#56) can be captured headlessly — the mock catalog has no tea, so we reuse a seed deck.
        if ProcessInfo.processInfo.environment["CRUMB_SINGLE"] == "1" { task = task.settingSingleItem(true) }
        enterPlan(with: task)
        curatorTier = nil
        clearRefinement()
        await loadCandidates(for: task)
        route = .missionThread
    }

    /// Screenshot hook: deal a deck, then answer it in prose the way the reported session did.
    ///
    /// `CRUMB_SAY` defaults to the verbatim message that used to be answered with a re-curation:
    /// *"I like it. Let's create a cart."* — decision and next step in one breath. Captures what
    /// that message does now, without needing a keyboard.
    func presentTypedAnswerForScreenshot(missionID: String) async {
        await presentCurateForScreenshot(missionID: missionID)
        let said = ProcessInfo.processInfo.environment["CRUMB_SAY"]
            ?? "I like it. Let\u{2019}s create a cart."
        submitMissionText(said)
    }

    /// Screenshot hook: deal a deck then accept every card, landing on Curate's "that's a
    /// kit" empty state so its art can be captured headlessly.
    func presentFullKitForScreenshot(missionID: String) async {
        await presentCurateForScreenshot(missionID: missionID)
        for product in deck { accept(product) }
    }

    /// Screenshot hook: land on the pre-gather mission thread for a seed mission (which carries a
    /// rich multi-part plan), so the plan-editor surface can be captured headlessly. The live
    /// composer can't be typed into via `simctl`; this stands in for a freshly planned mission.
    func presentPlanForScreenshot(missionID: String) {
        var task = missions.first { $0.id == missionID } ?? SeedData.hike
        if ProcessInfo.processInfo.environment["CRUMB_SINGLE"] == "1" { task = task.settingSingleItem(true) }
        enterPlan(with: task)
    }

    /// Screenshot hook: land on the Cart with a few shortlisted items across distinct shops, so the
    /// cart framing (kit grouping vs single-product compare-and-buy, #56/#60) captures headlessly.
    /// Seeds the kit directly from seed products — no live gather — so it never waits on the model.
    func presentCartForScreenshot(missionID: String) async {
        var task = missions.first { $0.id == missionID } ?? SeedData.hike
        if ProcessInfo.processInfo.environment["CRUMB_SINGLE"] == "1" { task = task.settingSingleItem(true) }
        enterPlan(with: task)
        curatorTier = nil
        clearRefinement()
        // Pick the first few products from distinct shops so the cart shows a real multi-shop spread.
        var chosen: [Product] = []
        var shops = Set<Shop.ID>()
        for product in SeedData.coffeeProducts where shops.insert(product.shop.id).inserted {
            chosen.append(product)
            if chosen.count == 3 { break }
        }
        mutateActiveThread {
            $0.kit = chosen.map(KitItem.init(product:))
            $0.phase = .deckReady
        }
        openCart()
    }

    /// Deterministic native sandbox checkout stages for screenshots and accessibility inspection.
    func presentSandboxCheckoutForScreenshot(missionID: String, stage: String) async {
        await presentCartForScreenshot(missionID: missionID)
        await startCheckoutWorkflow()
        guard let shop = checkoutWorkflow?.merchants.first?.shop else { return }
        if stage == "contact" { return }
        editSandboxCheckout(for: shop) {
            $0.firstName = "Sample"; $0.lastName = "Shopper"
            $0.email = "sample@example.invalid"; $0.street = "1 Sandbox Way"
            $0.city = "Testville"; $0.region = "CA"; $0.postalCode = "94107"; $0.country = "US"
        }
        await submitSandboxContact(for: shop)
        if stage == "completed" {
            editSandboxCheckout(for: shop) {
                $0.shippingSelections["shipment_1"] = "standard"
                $0.updateKey = nil
            }
            await submitSandboxContact(for: shop)
            acknowledgeSandboxReview(for: shop, acknowledged: true)
            await completeSandboxCheckout(for: shop)
        }
    }

    /// Screenshot hook: deal a mission's deck then run a canned `refinement` through the (sim's
    /// rule-based) interpreter so the reworked deck, the "Reworking…" state, and the refinement
    /// bar all render headlessly — `simctl` can inject neither taps nor keystrokes.
    func presentRefinedDeckForScreenshot(missionID: String, refinement: String) async {
        await presentCurateForScreenshot(missionID: missionID)
        await applyRefinement(text: refinement)
    }

    /// Screenshot hook: land on the History timeline (the store is seeded with deterministic
    /// entries — or left empty for the first-run state — in `CrumbApp`).
    func presentHistoryForScreenshot() {
        route = .history
    }

    /// Screenshot hook: open the read-only detail of the most recent seeded entry, so the kit,
    /// recap, and re-shop / plan-again actions render headlessly.
    func presentHistoryDetailForScreenshot() {
        if let first = historyEntries.first {
            openHistoryDetail(first)
        } else {
            route = .history
        }
    }

    /// Screenshot hook: land on the People roster (the store is seeded with deterministic people —
    /// or left empty for the "no people yet" state — in `CrumbApp`).
    func presentPeopleForScreenshot() {
        route = .people
    }

    /// Screenshot hook: land on Missions with a seeded recipient chosen in the composer, so the
    /// "Who's this for?" picker renders with someone selected (`simctl` can't tap a chip).
    func presentComposerGiftForScreenshot() {
        composerRecipient = recipients.first
        route = .missions
    }

    /// Screenshot hook: deal a **gift** curate deck — seeds `activeRecipient` (so curation reads the
    /// recipient's taste and the rule-based floor renders gift-framed voice) then deals the deck via
    /// the same proven path as ``presentCurateForScreenshot(missionID:)`` (which lands directly on
    /// Curate, never routing through the Plan step).
    func presentGiftCurateForScreenshot(missionID: String) async {
        var task = missions.first { $0.id == missionID } ?? SeedData.hike
        if ProcessInfo.processInfo.environment["CRUMB_SINGLE"] == "1" { task = task.settingSingleItem(true) }
        enterPlan(with: task, recipient: recipients.first)
        await loadCandidates(for: task)
        route = .missionThread
    }

    /// Screenshot hook: land on History filtered to the first seeded person, so the "for <name>"
    /// tags + the per-person filter chip row render headlessly.
    func presentGiftHistoryForScreenshot() {
        if let id = historyEntries.compactMap({ $0.recipient?.id }).first {
            historyRecipientFilter = .person(id)
        }
        route = .history
    }
    #endif

    func openCart() {
        let destination = isSingleProductMission ? "shortlist" : "kit"
        mutateActiveThread {
            $0.appendEvent(kind: .cartOpened, text: "Opened the \(destination).", createdAt: clock())
        }
        route = .cart
        // Reaching the cart with a kit is one of two save triggers (ending the mission is the
        // other): record (or update) this session's history entry. Fire-and-forget so navigation
        // stays instant; the recap is written async.
        recordKitToHistory()
    }

    func goToMissions() {
        cancelOperations()
        closeCheckoutWorkflow()
        // Returning to the composer resets the picker to Yourself — gifting is opt-in per mission.
        composerRecipient = nil
        planDecline = nil
        route = .missions
    }

    // MARK: History — writing the record

    /// Fire-and-forget wrapper over ``recordCurrentKit()`` (the recap write is async). Internal so
    /// tests can await the async core deterministically rather than racing the `Task`.
    func recordKitToHistory() {
        guard let threadID = activeThreadID else { return }
        Task { await recordCurrentKit(threadID: threadID) }
    }

    /// Snapshots the current kit into a ``HistoryEntry`` and saves it — the heart of the History
    /// feature. Writes only when there's a mission and at least one kept item (an abandoned plan
    /// with nothing kept is never recorded). Within one session it **upserts** the same entry
    /// (preserving its `createdAt` and any `handedOff` already earned), so back→edit→cart
    /// round-trips don't litter history with near-duplicates; a new mission (`enterPlan`) starts a
    /// fresh entry.
    ///
    /// Two correctness rules shape the order of work here:
    /// - **The row is saved synchronously *before* the slow on-device recap call**, seeded with the
    ///   deterministic floor recap and its id assigned, so the entry is complete and findable the
    ///   instant the user can act on it. Otherwise ``recordHandoffFollowed()`` could race the
    ///   awaited recap and silently no-op (the id wouldn't be set yet) on a real device.
    /// - **The recap is only (re)generated when the kept set actually changes.** A plain cart
    ///   re-reach reuses the stored recap, so a non-deterministic model can't make a kit's saved
    ///   title/line wobble between visits.
    func recordCurrentKit() async {
        guard let threadID = activeThreadID else { return }
        await recordCurrentKit(threadID: threadID)
    }

    /// Records one captured thread generation. The fire-and-forget cart path may begin after the
    /// user has already switched missions, so every value and post-await guard is tied to this id.
    private func recordCurrentKit(threadID: String) async {
        guard let thread = activeThread, thread.id == threadID,
              let task = thread.task, !thread.kit.isEmpty else { return }

        let items = thread.kit.map(HistoryItem.init)
        let goal = thread.goal
        let profile = thread.tasteSnapshot
        let recipientRef = thread.recipient.map(RecipientRef.init)

        // Reuse this session's id/createdAt/outcome on a re-reach; otherwise mint a new entry.
        let existing = thread.historyEntryID.flatMap { id in historyEntries.first { $0.id == id } }
        let id: String
        let createdAt: Date
        let handedOff: Bool
        if let existing {
            id = existing.id
            createdAt = existing.createdAt
            handedOff = existing.handedOff
        } else {
            let now = clock()
            id = "\(threadID)-\(UUID().uuidString)"
            createdAt = now
            handedOff = false
            guard activeThreadID == threadID else { return }
            mutateActiveThread { $0.historyEntryID = id }
        }

        let facts = items.map(RecapFact.init)
        let keptChanged = existing.map { Set($0.items.map(\.productID)) != Set(items.map(\.productID)) } ?? true

        // Snapshot who this kit was for (a gift) — `nil` for an owner kit. Captured at save time so
        // the entry stays a faithful receipt even if the person is later edited or deleted.
        func makeEntry(tag: String, line: String, handedOff: Bool) -> HistoryEntry {
            HistoryEntry(
                id: id, threadID: threadID, goal: goal, title: task.title, subtitle: task.subtitle,
                plan: task.plan, searchQueries: task.searchQueries, curatorNote: task.curatorNote,
                accentHex: task.accentHex, recapTag: tag, recapLine: line, items: items,
                recipient: recipientRef, handedOff: handedOff, createdAt: createdAt
            )
        }

        // Seed the recap: reuse the existing one when the kept set is unchanged (no jitter on a
        // plain re-reach); otherwise compute the deterministic floor *synchronously* so the saved
        // row is already complete before we await the on-device upgrade below.
        let seedTag: String
        let seedLine: String
        if let existing, !keptChanged {
            seedTag = existing.recapTag
            seedLine = existing.recapLine
        } else {
            let floor = RuleBasedRecapWriter.recap(
                goal: goal, plan: task.plan, items: facts, profile: profile,
                recipient: recipientRef, reason: nil
            )
            seedTag = floor.tag
            seedLine = floor.line
        }
        historyStore.save(makeEntry(tag: seedTag, line: seedLine, handedOff: handedOff))
        historyEntries = historyStore.loadEntries()

        // Upgrade with the on-device writer only when we (re)generated a recap. Best-effort and
        // race-safe: re-read the latest outcome (a handoff may have landed during the await) and
        // bail if the session moved on.
        guard keptChanged else { return }
        let written = await recapWriter.writeRecap(
            goal: goal, plan: task.plan, items: facts, profile: profile, recipient: recipientRef
        )
        guard activeThreadID == threadID, currentHistoryEntryID == id,
              let latest = historyEntries.first(where: { $0.id == id }) else { return }
        historyStore.save(makeEntry(tag: written.tag, line: written.line, handedOff: latest.handedOff))
        historyEntries = historyStore.loadEntries()
    }

    /// Flips this session's entry to "handed off" — called when the user actually opens a real
    /// checkout link from the handoff sheet (the honest outcome signal; a no-link handoff doesn't
    /// count). No-op if the kit never reached the cart this session.
    func recordHandoffFollowed() {
        guard let id = currentHistoryEntryID else { return }
        historyStore.setHandedOff(id, true)
        historyEntries = historyStore.loadEntries()
    }

    // MARK: History — reading & managing

    /// Opens the History timeline (the header affordance).
    func openHistory() {
        route = .history
    }

    /// Opens the read-only detail for a past entry.
    func openHistoryDetail(_ entry: HistoryEntry) {
        selectedHistoryEntry = entry
        route = .historyDetail
    }

    /// Deletes a single entry (swipe / menu), refreshing the timeline and stepping back out of a
    /// detail that was showing it.
    func deleteHistoryEntry(_ entry: HistoryEntry) {
        historyStore.delete(id: entry.id)
        historyEntries = historyStore.loadEntries()
        if selectedHistoryEntry?.id == entry.id {
            selectedHistoryEntry = nil
            if route == .historyDetail { route = .history }
        }
    }

    /// Clears the entire history ("Clear history"), returning to the now-empty timeline.
    func clearHistory() {
        historyStore.clear()
        historyEntries = []
        historyRecipientFilter = .all
        selectedHistoryEntry = nil
        if route == .historyDetail { route = .history }
    }

    /// Presents the re-shop sheet for a past entry (its snapshot's per-item buy links).
    func beginReshop(_ entry: HistoryEntry) {
        reshopEntry = entry
    }

    /// Routes a past entry's goal back through the direct planning chain — "Plan this again"
    /// shops it immediately. A new session, so building a kit from it becomes a new history entry.
    func planAgain(_ entry: HistoryEntry) {
        reshopEntry = nil
        selectedHistoryEntry = nil
        // Re-plan for the same person when the kit was a gift and they're still in the roster;
        // otherwise (owner kit, or a since-deleted person) re-plan for Yourself.
        let recipient = entry.recipient.flatMap { ref in recipients.first { $0.id == ref.id } }
        planMission(goal: entry.goal, for: recipient)
    }

    /// Steps one level back in the flow.
    func back() {
        switch route {
        case .onboarding, .missions: break  // roots — nothing to step back to
        case .missionThread:
            planDecline = nil
            route = .missions
        case .cart: route = .missionThread
        case .history: route = .missions
        case .historyDetail: route = .history
        case .people: route = .missions
        }
    }

    // MARK: Taste capture

    /// Finishes first-run onboarding with the profile the user built, persists it, and routes
    /// into the app. (No deck exists yet, so this never triggers a re-curate.)
    func completeOnboarding(with profile: TasteProfile) {
        updateTaste(profile)
        route = .missions
    }

    /// Skips onboarding: keep the seed profile but persist it, so the store now has a value and
    /// the user lands on the standard defaults instead of being asked again next launch.
    func skipOnboarding() {
        tasteStore.saveProfile(tasteProfile)
        route = .missions
    }

    /// The onboarding "let the goal lead" fast path: a brand-new user who just wants to shop can
    /// type what they're after and go, skipping the taste-capture steps. Fire-and-forget wrapper
    /// over ``runOnboardingGoal(_:)`` so the button stays synchronous; the async core is what tests
    /// drive deterministically. See issue #28.
    func startFromGoal(_ goal: String) {
        Task { await runOnboardingGoal(goal) }
    }

    /// Seeds an initial ``TasteProfile`` from the first goal (via the ``TasteExtractor`` seam,
    /// degrading to the seed default when no model), finishes onboarding with it (persisted, so
    /// onboarding never reappears), then plans the goal. A shoppable goal lands on the editable
    /// Plan; a non-shoppable one still completes onboarding and drops the user on Missions with the
    /// friendly decline, never stranded on the onboarding screen. Internal (not private) so tests
    /// can await it rather than racing the fire-and-forget `Task`.
    func runOnboardingGoal(_ goal: String) async {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPlanning else { return }
        // Hold the "planning" flag across the whole path — taste extraction runs on-device and can
        // take a moment, and this keeps the Start button disabled + spinning so a second tap can't
        // kick off a duplicate plan before `runPlan` takes over the flag.
        isPlanning = true
        // Infer taste from the goal; fall back to the current (seed) profile when no model reads it.
        let seeded = await extractTaste(from: trimmed, base: tasteProfile) ?? tasteProfile
        completeOnboarding(with: seeded)
        await runPlan(goal: trimmed)   // re-asserts isPlanning and clears it in its own defer
    }

    /// Replaces the taste profile, persists it, and — when a deck is already on screen —
    /// **re-curates it in place** so the change is *felt*: the live candidates re-rank and
    /// re-voice against the new taste without re-fetching the catalog. A no-op deck (nothing
    /// loaded yet) just persists.
    func updateTaste(_ profile: TasteProfile) {
        tasteProfile = profile
        tasteStore.saveProfile(profile)
        if activeThread?.recipient == nil {
            mutateActiveThread { $0.tasteSnapshot = profile }
        }
        guard !candidates.isEmpty else { return }
        Task { await recurateCurrentDeck() }
    }

    /// Re-ranks and re-voices the current candidate set against the latest `tasteProfile`,
    /// preserving the kit and re-dealing the rest in the new order. Used by ``updateTaste(_:)``
    /// so an edit visibly reshapes the deck the user is looking at. Internal (not private) so
    /// tests can drive the re-curate deterministically rather than racing the fire-and-forget
    /// `Task` that ``updateTaste(_:)`` kicks off.
    func recurateCurrentDeck() async {
        guard let task = selectedTask, !candidates.isEmpty, let threadID = activeThreadID,
              let operationID = beginOperation(.curation) else { return }
        isRecurating = true

        let curated = await curator.curate(candidates, for: activeTaste, mission: task, refinement: nil, recipient: activeRecipientRef)
        guard operationIsCurrent(.curation, id: operationID, threadID: threadID) else { return }
        isRecurating = false
        finishOperation(.curation, id: operationID)
        let priced = PriceBand.priceSane(curated.products)
        let excludedIDs = excludedDeckProductIDs
        mutateActiveThread {
            $0.candidates = priced
            $0.remainingDeckIDs = priced.map(\.id).filter { !excludedIDs.contains($0) }
            installNextProductOrKitQuestion(in: &$0)
        }
        curatorTier = curated.tier
    }

    // MARK: Conversational refinement

    /// Applies a typed/chip refinement to the dealt deck (the Curate bar's submit). Fire-and-forget
    /// wrapper over ``applyRefinement(text:)`` so the bar stays synchronous; the async core is what
    /// tests drive deterministically.
    func refine(_ text: String) {
        launchedOperationTasks[.refinement]?.cancel()
        let launched = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyRefinement(text: text)
        }
        launchedOperationTasks[.refinement] = launched
    }

    /// Reworks the current deck from a refinement line: interprets it (in the context of the
    /// running conversation) into a ``RefinementDirective``, re-searches + merges only when the
    /// directive carries `addQueries`, then re-curates the working set with the directive so
    /// ranking AND voice honor it. The kit is preserved; the rest is re-dealt in the new order.
    /// Internal (not private) so tests can await it rather than racing the fire-and-forget `Task`.
    func applyRefinement(text: String) async {
        await applyRefinement(text: text, appendUserEvent: true)
    }

    private func applyRefinement(text: String, appendUserEvent: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = selectedTask, !trimmed.isEmpty, !candidates.isEmpty,
              let threadID = activeThreadID, let operationID = beginOperation(.refinement) else { return }

        isReworking = true
        let retry = MissionRetryDescriptor(
            kind: .refinement, input: trimmed, taskRevision: activeThread?.revision, returnPhase: .deckReady
        )
        mutateActiveThread {
            $0.refinementTurns.append(trimmed)
            $0.pendingOperation = MissionPendingOperation(id: operationID, retry: retry, startedAt: clock())
            $0.retry = nil
            if appendUserEvent {
                $0.appendEvent(kind: .userMessage, text: trimmed, createdAt: clock(), operationID: operationID)
            }
            $0.appendEvent(kind: .refinementRequested, text: "Reworking the picks…", createdAt: clock(), operationID: operationID)
            installWorkingQuestion(in: &$0, operationID: operationID, title: "Reworking the picks…", context: "refinement")
        }
        let conversation = refinementTurns

        let interpreted = await refiner.interpret(
            trimmed, conversation: conversation, mission: task, profile: activeTaste
        )
        guard operationIsCurrent(.refinement, id: operationID, threadID: threadID) else { return }
        refinementTier = interpreted.tier

        // Pull in new candidates only when the refinement asked for something not in the deck
        // (e.g. "add rain pants"); otherwise re-curate the existing deck in place.
        var working = candidates
        if !interpreted.directive.addQueries.isEmpty, let found = await search(interpreted.directive.addQueries) {
            guard operationIsCurrent(.refinement, id: operationID, threadID: threadID) else { return }
            var seen = Set(working.map(\.id))
            working += found.filter { seen.insert($0.id).inserted }
        }

        let context = RefinementContext(directive: interpreted.directive, conversation: conversation)
        let curated = await curator.curate(working, for: activeTaste, mission: task, refinement: context, recipient: activeRecipientRef)
        guard operationIsCurrent(.refinement, id: operationID, threadID: threadID) else { return }
        isReworking = false
        finishOperation(.refinement, id: operationID)
        // Keep the price backstop on refinement too — unless the user explicitly asked to go
        // pricier, in which case honor it and leave the order the curator produced.
        let priced = interpreted.directive.priceDirection == .pricier
            ? curated.products
            : PriceBand.priceSane(curated.products)
        let excludedIDs = excludedDeckProductIDs
        mutateActiveThread {
            $0.refinementDirectives.append(interpreted.directive)
            $0.candidates = priced
            $0.remainingDeckIDs = priced.map(\.id).filter { !excludedIDs.contains($0) }
            $0.phase = .deckReady
            $0.pendingOperation = nil
            $0.retry = nil
            $0.appendEvent(kind: .refinementApplied, text: "I updated the picks to match.", createdAt: clock(), operationID: operationID)
            installNextProductOrKitQuestion(in: &$0, includeRefinementFollowUps: true)
        }
        curatorTier = curated.tier
        canSaveRefinementToTaste = refinementDirectives.contains { $0.isActionable }
    }

    /// Clears the refinement conversation and restores the deck as first dealt (the
    /// ``baseCandidates`` snapshot), preserving the kit. Synchronous and model-free — the base
    /// deck already carries Crumb's voice, so Reset is an instant undo, not a re-curate.
    func resetRefinements() {
        let restored = baseCandidates
        let excludedIDs = excludedDeckProductIDs
        mutateActiveThread {
            let refinementOperations = Set($0.timeline.compactMap {
                $0.kind == .refinementRequested ? $0.operationID : nil
            })
            for index in $0.timeline.indices {
                let event = $0.timeline[index]
                if event.kind == .refinementApplied
                    || (event.kind == .userMessage && event.operationID.map(refinementOperations.contains) == true) {
                    $0.timeline[index].isSuperseded = true
                }
            }
            $0.refinementTurns = []
            $0.refinementDirectives = []
            $0.candidates = restored
            $0.remainingDeckIDs = restored.map(\.id).filter { !excludedIDs.contains($0) }
            $0.appendEvent(kind: .refinementsReset, text: "Reset the conversation changes.", createdAt: clock())
        }
        refinementTier = nil
        canSaveRefinementToTaste = false
        isReworking = false
    }

    /// Folds the accumulated refinement into the persisted ``TasteProfile`` so future missions
    /// inherit it (the quiet, opt-in "make this part of your taste"). Primary path: re-read the
    /// refinement text through the injected ``TasteExtractor`` (richer, on-device). Floor: when no
    /// model is available (sim/CI → `nil`), fold the structured directives deterministically so
    /// the save still does something honest and is testable. Persists but does **not** re-curate —
    /// the on-screen deck already reflects the refinement; this is for *next* time.
    func saveRefinementToTaste() async {
        guard canSaveRefinementToTaste, !refinementTurns.isEmpty, let threadID = activeThreadID else { return }
        let combined = refinementTurns.joined(separator: ". ")
        // Fold into whichever taste this mission is curating through: the recipient's during a gift
        // mission (so it sticks next time you shop for them — the owner's profile is untouched), or
        // the owner's otherwise (exactly today's behavior).
        let base = activeTaste
        let extracted = await tasteExtractor.extract(from: combined, base: base)
        guard activeThreadID == threadID else { return }
        let updated = (extracted ?? Self.fold(refinementDirectives, into: base)).normalized

        if let recipient = activeRecipient {
            updateRecipientTaste(recipient, updated)
        } else {
            tasteProfile = updated
            tasteStore.saveProfile(updated)
        }
        canSaveRefinementToTaste = false
    }

    private func performQueuedTasteSave() async {
        let threadID = activeThreadID
        await saveRefinementToTaste()
        guard activeThreadID == threadID,
              activeThread?.pendingOperation?.retry.kind == .chips,
              activeThread?.pendingOperation?.retry.input == "save-to-taste" else { return }
        mutateActiveThread {
            $0.pendingOperation = nil
            $0.retry = nil
            installNextProductOrKitQuestion(in: &$0)
        }
    }

    /// Deterministically folds refinement directives into a profile (the no-model floor for
    /// "save to taste"): a price lean nudges `budgetComfort`, an emphasis becomes a leaning, and a
    /// remove hint becomes a "Less …" leaning. The caller normalizes (clamp + dedupe), so repeated
    /// or conflicting asks can't corrupt the profile.
    static func fold(_ directives: [RefinementDirective], into base: TasteProfile) -> TasteProfile {
        var leanings = base.leanings
        var budget = base.budgetComfort
        for directive in directives {
            switch directive.priceDirection {
            case .cheaper: budget -= 0.15
            case .pricier: budget += 0.15
            case .none: break
            }
            let emphasis = directive.emphasis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !emphasis.isEmpty { leanings.append(emphasis) }
            for hint in directive.removeHints { leanings.append("Less \(hint)") }
        }
        return TasteProfile(
            vibe: base.vibe,
            leanings: leanings,
            budgetComfort: budget,
            signatureLine: base.signatureLine
        )
    }

    /// Parses a free-text self-description into a profile via the injected ``TasteExtractor``,
    /// topping up `base` for anything the text doesn't cover. `nil` means "no parse" (no model
    /// available) — the caller keeps the user's hand-set values. Pure delegation, kept here so
    /// the views talk only to the model.
    func extractTaste(from text: String, base: TasteProfile) async -> TasteProfile? {
        await tasteExtractor.extract(from: text, base: base)
    }

    /// Fire-and-forget nudge to wake the (scale-to-zero) broker on launch, so the first live
    /// mission usually loads warm. No-op on the mock.
    func warmUpCatalog() async {
        await ucp.warmUp()
    }

    // MARK: People — the roster you shop for

    /// Opens the "People you shop for" screen (the header affordance).
    func openPeople() {
        route = .people
    }

    /// Adds a new person to the roster and returns them, so a caller (the composer's "Add someone")
    /// can immediately select them. A fresh `id`, the next palette accent by add-order, and a
    /// `createdAt` from the injected clock (deterministic in tests). The taste comes pre-built from
    /// the editor (free-text parse + hand-tuning), normalized before it's stored.
    @discardableResult
    func addRecipient(name: String, relationship: String?, taste: TasteProfile) -> Recipient {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRel = relationship?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accent = Self.recipientAccents[recipients.count % Self.recipientAccents.count]
        let recipient = Recipient(
            id: UUID().uuidString,
            name: trimmedName,
            relationship: (trimmedRel?.isEmpty ?? true) ? nil : trimmedRel,
            taste: taste.normalized,
            accentHex: accent,
            createdAt: clock()
        )
        recipientStore.save(recipient)
        recipients = recipientStore.loadRecipients()
        return recipient
    }

    /// Replaces an existing person (the editor's Save), keeping their identity/accent/createdAt.
    /// Normalizes taste, re-persists, refreshes the roster, and — if they're the active mission's
    /// recipient — updates the live `activeRecipient` so `activeTaste` reflects the edit at once.
    func updateRecipient(_ recipient: Recipient) {
        var updated = recipient
        updated.taste = recipient.taste.normalized
        recipientStore.save(updated)
        recipients = recipientStore.loadRecipients()
        if activeRecipient?.id == updated.id {
            mutateActiveThread {
                $0.recipient = updated
                $0.tasteSnapshot = updated.taste
            }
        }
        if composerRecipient?.id == updated.id { composerRecipient = updated }
    }

    /// Folds a new taste into a person's saved profile — the gift-mission "save to taste" target.
    /// Re-persists and keeps the live `activeRecipient` in sync so the on-screen deck's lens updates.
    func updateRecipientTaste(_ recipient: Recipient, _ taste: TasteProfile) {
        var updated = recipient
        updated.taste = taste.normalized
        updateRecipient(updated)
    }

    /// Removes a person from the roster. Clears them from the composer selection and resets a
    /// History filter that was narrowed to them (so the timeline never dangles on an empty filter).
    /// The active mission keeps its snapshot recipient — a mid-mission delete shouldn't change the
    /// deck you're looking at.
    func deleteRecipient(id: String) {
        recipientStore.delete(id: id)
        recipients = recipientStore.loadRecipients()
        if composerRecipient?.id == id { composerRecipient = nil }
        if historyRecipientFilter == .person(id) { historyRecipientFilter = .all }
    }

    /// Parses a free-text description of a person into a ``TasteProfile`` via the injected
    /// ``TasteExtractor`` (the same seam the owner editor uses). Pure delegation — it never touches
    /// the owner profile — so the person editor can reuse `DescribeYourselfCard` unchanged. `nil`
    /// means "no parse" (no model available); the caller keeps the hand-set values.
    func extractRecipientTaste(from text: String, base: TasteProfile) async -> TasteProfile? {
        await tasteExtractor.extract(from: text, base: base)
    }

    // MARK: Curation

    /// The fewest candidates the relevance gate will ever leave on a non-empty result set, so an
    /// over-eager gate can never produce "no matches". Chosen ≥ the largest mock/seed deck so the
    /// scaffold's decks (all relevant to their mission) always pass through untouched; only larger
    /// live decks, where off-topic noise actually appears, get trimmed.
    static let relevanceFloor = 8

    /// The deterministic, model-free curator used to order the *streamed* pre-settle deck with the
    /// mission-aware floor (#58) — the trustworthy ranking shown before curation settles.
    static let streamFloor = RuleBasedCurator()

    /// Fans the mission's `searchQueries` out to the catalog **in parallel**, dedupes the
    /// union by product id, and hands it to the curator for one ranked deck.
    ///
    /// Failure semantics: each query succeeds or fails independently — a single failed
    /// query just contributes nothing. Only when *every* query errors (broker down /
    /// offline) do we surface ``LoadState/failed`` (retryable), so a real outage is never
    /// mistaken for an empty-but-successful result.
    ///
    /// The mock resolves all of a mission's queries back to the same seed candidates, so
    /// the dedupe collapses them to that mission's curated set — mock behavior is
    /// unchanged.
    func loadCandidates(for task: ShoppingTask) async {
        guard let threadID = activeThreadID, let operationID = beginOperation(.gathering) else { return }
        let retry = MissionRetryDescriptor(
            kind: .gathering,
            input: task.searchQueries.joined(separator: "\n"),
            taskRevision: activeThread?.revision,
            returnPhase: .planReady
        )
        mutateActiveThread {
            $0.phase = .gathering
            $0.pendingOperation = MissionPendingOperation(id: operationID, retry: retry, startedAt: clock())
            $0.retry = nil
            if $0.timeline.last?.kind != .gatheringStarted {
                $0.appendEvent(kind: .gatheringStarted, text: "Searching the shops…", createdAt: clock(), operationID: operationID)
            }
            installWorkingQuestion(in: &$0, operationID: operationID, title: "Searching the shops…", context: "gathering")
        }
        loadState = .loading
        settleWatchdog?.cancel()
        curationRefiningOvertime = false
        // Fit the Curate refine chips to this mission the moment its deck starts dealing — the
        // universal choke point every deal path funnels through (live select/curate, the gift and
        // screenshot deep-entries), so the chips are ready before Curate appears regardless of route.
        refreshRefineChips(for: task)

        // Stream raw, then settle. The gather streams each newly-discovered batch through the
        // collector; we append raw picks to the deck the moment they land and flip to Curate on the
        // FIRST pick — so the user watches the deck fill instead of staring at "Scanning shops" until
        // the whole pipeline settles. Once gather + curate finish we swap the raw deck for the ranked,
        // voiced one (see `settledDeck`).
        let collector = CandidateCollector()
        let streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await batch in collector.picks {
                guard self.operationIsCurrent(.gathering, id: operationID, threadID: threadID) else { break }
                let fresh = batch.filter { product in !self.candidates.contains { $0.id == product.id } }
                guard !fresh.isEmpty else { continue }
                // Voice each streamed pick with the deterministic floor the instant it lands, so the
                // deck never shows the raw merchant blurb as the "why this is you" — not even in the
                // stream-raw window before curation settles (#22). The settle then swaps in the
                // ranked, model-voiced deck; this is the immediate, model-free curator line, and it
                // matches what the settled deck falls back to if the on-device model can't rank.
                let voicedFresh = fresh.map {
                    $0.withRationale(self.curator.rationale(for: $0, profile: self.activeTaste, recipient: self.activeRecipientRef, mission: task))
                }
                let wasEmpty = self.deck.isEmpty
                // Order the streamed floor with the same mission-aware rank the settle uses (#58): for a
                // premium-tea search this leads with credible specialty picks and sinks bulk / sample /
                // sachet listings, instead of showing whatever order the live searches returned in —
                // model-free, so it's the trustworthy floor even before curation settles.
                let ranked = Self.streamFloor.rank(self.candidates + voicedFresh, for: self.activeTaste, mission: task)
                let excludedIDs = self.excludedDeckProductIDs
                self.mutateActiveThread {
                    $0.candidates = ranked
                    $0.remainingDeckIDs = ranked.map(\.id).filter { !excludedIDs.contains($0) }
                    $0.appendEvent(
                        kind: .productsFound,
                        text: "Found \(ranked.count) \(ranked.count == 1 ? "option" : "options") so far.",
                        createdAt: self.clock(),
                        operationID: operationID
                    )
                }
                if wasEmpty {
                    // First pick: the deck is now actionable. Navigate to Curate and flip out of the
                    // blocking "loading" state into "refining" — the gather/curation keep settling,
                    // but the user can already swipe, so the banner must not read as a blocking
                    // spinner (#57). Arm the watchdog that downgrades it if the settle runs long.
                    self.route = .missionThread
                    self.loadState = .refining
                    self.startSettleWatchdog(for: task, operationID: operationID, threadID: threadID)
                }
            }
        }

        // The agentic orchestrator lets the model *drive* the search via Tools (searching each part,
        // reaching past the plan, widening a strong fit) with the relevance guard on every result; it
        // degrades to the deterministic parallel fan-out + gate when no model is up. Off-topic items
        // are dropped before the curator ranks/voices them, and the floor keeps at least
        // `relevanceFloor` candidates so a real result set never becomes "no matches". Returns nil
        // only on a total catalog outage.
        let gathered = await CrumbTrace.measure("gather", summarize: {
            "queries=\(task.searchQueries.count) candidates=\($0?.products.count ?? 0) agent=\($0?.usedAgent ?? false)"
        }) { () -> GatheredCandidates? in
            async let picks = orchestrator.gather(for: task, floor: Self.relevanceFloor, using: ucp, gate: relevanceGate, into: collector)
            #if DEBUG
            // Put a floor under how long the search takes, for a UI test that has to act *during*
            // one. Measured on a warm simulator, a gather can settle in under a second — the deck
            // is already on the product question by the time a UI test finishes mounting the
            // screen — so `testMidGatherRefinementBuffersAndApplies` had no window to type into and
            // failed ~30% of runs. This is a floor, not a stall: the orchestrator above is already
            // running, batches stream into the deck throughout, and the mission passes through the
            // same `.refining` state with a filling deck that a real user types into. A slow
            // gather is unaffected, and nothing here is compiled into a Release build.
            if let hold = ProcessInfo.processInfo.environment["CRUMB_UITEST_GATHER_HOLD_MS"]
                .flatMap(UInt64.init), hold > 0 {
                try? await Task.sleep(nanoseconds: hold * 1_000_000)
            }
            #endif
            return await picks
        }
        await collector.finish()      // close the stream so the subscriber's loop ends…
        _ = await streamTask.value    // …and drain any trailing picks before we settle the deck.

        guard operationIsCurrent(.gathering, id: operationID, threadID: threadID) else { return }

        guard let gathered else {
            settleWatchdog?.cancel()
            mutateActiveThread {
                $0.candidates = []
                $0.baseCandidates = []
                $0.remainingDeckIDs = []
                $0.phase = .failed
                $0.pendingOperation = nil
                $0.retry = retry
                $0.appendEvent(kind: .failure, text: "I couldn't reach the shops. You can retry when you're ready.", createdAt: clock(), operationID: operationID)
                installRetryQuestion(in: &$0, retry: retry)
            }
            finishOperation(.gathering, id: operationID)
            loadState = .failed
            curationRefiningOvertime = false
            return
        }

        // `curate` both ranks and rewrites each rationale into Crumb's voice, and reports the tier
        // it used so the UI can be honest when it fell back from the AI curator. Bounded by
        // `curationSettleDeadline`: a hung on-device model turn returns `nil` and we settle with the
        // streamed, deterministically-voiced deck rather than spin forever (#57). For a gift mission
        // this curates to the recipient's taste, with gift-framed voice.
        let curated = await curateBounded(gathered.products, for: task)
        guard operationIsCurrent(.gathering, id: operationID, threadID: threadID) else { return }
        settleWatchdog?.cancel()

        // Price sanity: sink any wildly-mispriced catalog outlier (the $1,450 "Premium Black Tea
        // Leaf" against a $4–$60 norm) to the tail *after* the curator has ranked, so it can never
        // lead or reach the top-3 — in every curator tier, offline included. A deck with too few
        // priced items to judge a band passes through untouched. On a settle timeout we price-sane
        // the streamed deck (already deterministically voiced) and mark the honest fallback tier.
        let priced: [Product]
        if let curated {
            priced = PriceBand.priceSane(curated.products)
            curatorTier = curated.tier
        } else {
            priced = PriceBand.priceSane(deck)
            curatorTier = .ruleBased(.modelNotReady)
        }
        // Settle: swap the streamed raw deck for the curated (ranked, voiced, price-saned) order,
        // keeping only cards the user hasn't already swiped past.
        let settled = Self.settledDeck(priced, keepingUndecidedFrom: deck)
        mutateActiveThread {
            $0.candidates = priced
            $0.baseCandidates = priced
            $0.remainingDeckIDs = settled.map(\.id)
            $0.phase = .deckReady
            $0.pendingOperation = nil
            $0.retry = nil
            $0.appendEvent(
                kind: .gatheringCompleted,
                text: "\(priced.count) \(priced.count == 1 ? "pick" : "picks") ready to explore.",
                createdAt: clock(),
                operationID: operationID
            )
            installNextProductOrKitQuestion(in: &$0)
        }
        finishOperation(.gathering, id: operationID)
        loadState = .loaded
        curationRefiningOvertime = false
        // If nothing streamed (a successful but empty gather), the stream never navigated us — land
        // on Curate anyway so the empty state shows, matching the pre-streaming behavior.
        if route != .missionThread { route = .missionThread }
        // Note: the refinement conversation is reset by `enterPlan` (a new mission) and the
        // screenshot hook, NOT here — clearing it on every (re)load would race a refinement that
        // arrived while an earlier load was still settling.

        // Free text typed while we were searching was queued rather than cancelling the gather —
        // run it now that the deck has settled. With nothing gathered there's no deck to rework,
        // so the ask folds into the goal and the direct chain searches again.
        let queued = activeThread?.queuedRefinements ?? []
        if !queued.isEmpty {
            mutateActiveThread { $0.queuedRefinements = nil }
            let text = queued.joined(separator: ". ")
            if candidates.isEmpty {
                let goal = activeThread?.goal ?? task.title
                await retryPlanningInActiveThread(goal: "\(goal), \(text)", appendUserEvent: false)
            } else {
                await applyRefinement(text: text, appendUserEvent: false)
            }
        }
    }

    /// Arms the settle watchdog for `task`: if the load is still ``LoadState/refining`` after
    /// ``curationSettleWindow`` seconds, downgrade the "Curating your picks…" spinner to the quiet,
    /// non-blocking "still personalizing" status so a usable deck is never sat behind an indefinite
    /// spinner (#57). No-ops if the deck settled, failed, or the user moved to another mission first.
    private func startSettleWatchdog(for task: ShoppingTask, operationID: String, threadID: String) {
        settleWatchdog?.cancel()
        let window = curationSettleWindow
        settleWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard let self, !Task.isCancelled,
                  self.operationIsCurrent(.gathering, id: operationID, threadID: threadID),
                  self.loadState == .refining else { return }
            self.curationRefiningOvertime = true
        }
    }

    /// Runs the curation settle bounded by ``curationSettleDeadline``. Returns the curated deck, or
    /// `nil` if the curator's ranking/voice didn't finish in time — so the caller settles with the
    /// streamed deterministic deck instead of holding the user behind a hung model turn (#57).
    ///
    /// Mirrors the gather safety net's abandon-on-deadline shape (#54): the curate runs in an
    /// unstructured task raced against a deadline; on timeout the task is cancelled and its result
    /// dropped (it never mutates the model — it only yields to the race), so a runaway on-device turn
    /// can't block the settle.
    private func curateBounded(_ products: [Product], for task: ShoppingTask) async -> CuratedDeck? {
        let curator = self.curator
        let taste = self.activeTaste
        let recipient = self.activeRecipientRef
        enum SettleEnd { case done(CuratedDeck); case timedOut }
        let (signals, continuation) = AsyncStream.makeStream(of: SettleEnd.self)
        let curateTask = Task { @MainActor in
            let deck = await CrumbTrace.measure("curate", summarize: {
                "in=\(products.count) deck=\($0.products.count) tier=\($0.tier.traceLabel)"
            }) {
                await curator.curate(products, for: taste, mission: task, refinement: nil, recipient: recipient)
            }
            continuation.yield(.done(deck))
        }
        let deadlineTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(curationSettleDeadline)); continuation.yield(.timedOut) }
            catch { /* cancelled because curation finished first — no deadline signal */ }
        }
        var end: SettleEnd = .timedOut
        for await signal in signals { end = signal; break }
        deadlineTask.cancel()
        if case .done(let deck) = end { return deck }
        curateTask.cancel()   // abandon the runaway curation (cooperative); its result is dropped
        CrumbTrace.emit(stage: "curate", elapsedMillis: Int(curationSettleDeadline * 1000),
                        summary: "settle deadline — fell back to streamed deck")
        return nil
    }

    /// Swaps the streamed raw deck for the curated one at "settle" time: returns the curated (ranked,
    /// voiced) products in their ranked order, dropping any the user already swiped past while the
    /// deck was streaming. By settle time everything gathered has streamed, so a curated product
    /// missing from `current` was decided, not merely unseen; a still-present one is undecided and
    /// keeps its ranked position. When nothing has streamed yet (`current` empty — e.g. a fully
    /// synchronous path), the full ranked deck is used as-is. Pure — unit-tested.
    nonisolated static func settledDeck(_ settled: [Product], keepingUndecidedFrom current: [Product]) -> [Product] {
        guard !current.isEmpty else { return settled }
        let undecided = Set(current.map(\.id))
        return settled.filter { undecided.contains($0.id) }
    }

    /// Fans `queries` out to the catalog **in parallel** and dedupes the union by product id.
    /// Returns `nil` only when *every* query errored (a real outage), so the caller can tell an
    /// outage from a successful-but-empty result. Shared by the initial ``loadCandidates(for:)``
    /// and by an `addQueries` refinement, so both fan out and dedupe identically.
    private func search(_ queries: [String]) async -> [Product]? {
        // The parallel fan-out + dedupe now lives in CrumbKit as `UCPClient.searchUnion`, shared
        // with the deterministic orchestrator so a refinement's `addQueries` search behaves
        // identically to the initial gather.
        await ucp.searchUnion(queries)
    }

    // MARK: Swipe deck

    /// Accept the current top card: add it to the kit and advance the deck.
    func accept(_ product: Product) {
        if let submission = productInteractionSubmission(productID: product.id, optionID: "add") {
            submitMissionAnswer(submission)
            return
        }
        guard activeThread?.pendingInteraction == nil else { return }
        guard !isInKit(product) else { return }
        let destination = isSingleProductMission ? "shortlist" : "kit"
        let operationID = UUID().uuidString
        mutateActiveThread {
            $0.kit.append(KitItem(product: product))
            $0.remainingDeckIDs.removeAll { $0 == product.id }
            $0.decisions.append(MissionProductDecision(
                id: operationID, kind: .added, productID: product.id,
                variantID: product.variants.first?.id, createdAt: clock()
            ))
            $0.appendEvent(kind: .productAdded, text: "Added \(product.name) to the \(destination).", createdAt: clock(), productID: product.id, operationID: operationID)
        }
    }

    /// Skip the current top card without adding it.
    func skip(_ product: Product) {
        if let submission = productInteractionSubmission(productID: product.id, optionID: "skip") {
            submitMissionAnswer(submission)
            return
        }
        guard activeThread?.pendingInteraction == nil else { return }
        guard deck.contains(where: { $0.id == product.id }) else { return }
        let operationID = UUID().uuidString
        mutateActiveThread {
            $0.remainingDeckIDs.removeAll { $0 == product.id }
            $0.decisions.append(MissionProductDecision(
                id: operationID, kind: .skipped, productID: product.id, createdAt: clock()
            ))
            $0.appendEvent(kind: .productSkipped, text: "Skipped \(product.name).", createdAt: clock(), productID: product.id, operationID: operationID)
        }
    }

    func removeFromKit(_ item: KitItem) {
        guard kit.contains(where: { $0.id == item.id }) else { return }
        let operationID = UUID().uuidString
        mutateActiveThread {
            $0.kit.removeAll { $0.id == item.id }
            $0.decisions.append(MissionProductDecision(
                id: operationID, kind: .removed, productID: item.product.id,
                variantID: item.variant.id, createdAt: clock()
            ))
            $0.appendEvent(kind: .productRemoved, text: "Removed \(item.product.name).", createdAt: clock(), productID: item.product.id, operationID: operationID)
        }
    }

    /// Re-deal any candidates not currently in the kit (used by "Find more").
    func reshuffleDeck() {
        let kitIDs = Set(kit.map { $0.product.id })
        mutateActiveThread {
            $0.decisions.removeAll { $0.kind == .skipped }
            $0.remainingDeckIDs = $0.candidates.map(\.id).filter { !kitIDs.contains($0) }
            $0.appendEvent(kind: .notice, text: "Put the skipped picks back into the deck.", createdAt: clock())
        }
    }

    // MARK: App Intents / onscreen entities (issue #41)

    /// The mission's full curated pool — the products App Intents can resolve a ``ProductEntity``
    /// against (the visible deck plus anything already swiped into the kit).
    var sessionProducts: [Product] { candidates }

    /// Resolves only an undecided, currently actionable card. Mutating App Intents use this rather
    /// than the full session pool so a stale Skip/Add request cannot resurrect a decided product.
    func deckProduct(id: Product.ID) -> Product? { deck.first { $0.id == id } }

    /// The visible swipe deck (undecided cards) — the entities Siri should *suggest*, since those
    /// are what the user is looking at right now.
    var deckProducts: [Product] { deck }

    /// Resolves a session product by id for an App Intent acting on the deck; `nil` when the id is
    /// stale (the mission changed, or the app cold-launched with no deck) so the intent can fail
    /// honestly instead of mutating nothing.
    func sessionProduct(id: Product.ID) -> Product? {
        candidates.first { $0.id == id }
    }

    /// The kit's running subtotal (sum of each item's price) — surfaced in the App Intent
    /// confirmation snippet after a hands-free "add to kit".
    var kitSubtotal: Decimal {
        kit.reduce(Decimal(0)) { $0 + $1.product.price }
    }

    // MARK: Checkout handoff (per shop)

    /// Starts one checkout-preparation workflow for the current kit. Each merchant is independent:
    /// one unsupported or failed shop never hides checkouts that another shop prepared successfully.
    /// A non-nil, preparing workflow is also the double-tap guard for the cart CTA.
    func startCheckoutWorkflow() async {
        guard checkoutWorkflow == nil, !currentCart.items.isEmpty else { return }

        let cart = currentCart
        let workflowID = UUID()
        checkoutWorkflow = CheckoutWorkflow(
            id: workflowID,
            merchants: cart.shops.map { shop in
                MerchantCheckout(
                    shop: shop,
                    items: cart.items(for: shop),
                    idempotencyKey: "crumb-\(UUID().uuidString)",
                    state: .preparing,
                    sandbox: nil
                )
            }
        )

        // Prepare independently. Keep this sequential for now: it makes state transitions fully
        // deterministic for VoiceOver and tests, while each merchant remains individually retryable.
        for shop in cart.shops {
            await prepareCheckout(for: shop, in: cart, workflowID: workflowID)
        }
    }

    /// Starts the same UCP workflow for exactly one shortlisted alternative. This preserves the
    /// single-product mission's pick-one semantics while avoiding the legacy URL-only path.
    func startCheckoutWorkflow(for item: KitItem) async {
        guard checkoutWorkflow == nil else { return }
        let workflowID = UUID()
        let merchant = MerchantCheckout(
            shop: item.product.shop,
            items: [item],
            idempotencyKey: "crumb-\(UUID().uuidString)",
            state: .preparing,
            sandbox: nil
        )
        checkoutWorkflow = CheckoutWorkflow(id: workflowID, merchants: [merchant])
        await prepareCheckout(for: item.product.shop, in: Cart(items: [item]), workflowID: workflowID)
    }

    /// Retries only one merchant and deliberately reuses its original idempotency key.
    func retryCheckout(for shop: Shop) async {
        guard var workflow = checkoutWorkflow,
              let index = workflow.merchants.firstIndex(where: { $0.shop.id == shop.id }),
              workflow.merchants[index].state != .preparing else { return }
        workflow.merchants[index].state = .preparing
        checkoutWorkflow = workflow
        await prepareCheckout(for: shop, in: Cart(items: workflow.merchants.flatMap(\.items)), workflowID: workflow.id)
    }

    private func prepareCheckout(for shop: Shop, in cart: Cart, workflowID: UUID) async {
        guard let workflow = checkoutWorkflow, workflow.id == workflowID,
              let merchant = workflow.merchants.first(where: { $0.shop.id == shop.id }) else { return }
        do {
            let session = try await ucp.createCheckout(
                for: shop, items: merchant.items, idempotencyKey: merchant.idempotencyKey
            )
            updateCheckout(shopID: shop.id, workflowID: workflowID, state: .prepared(session))
            if case .sandbox = session.provenance {
                var sandbox = SandboxCheckout()
                if let expiry = session.expiresAt, expiry <= Date() { sandbox.phase = .expired }
                updateSandbox(shopID: shop.id, workflowID: workflowID) { $0 = sandbox }
            }
        } catch UCPError.checkoutUnsupported(_) {
            // UCP checkout is not available for this merchant. Resolve the existing safe merchant
            // handoff as a clearly labeled fallback, never as a prepared UCP checkout.
            let fallback = try? await ucp.checkoutHandoff(
                for: shop, in: Cart(items: merchant.items)
            )
            updateCheckout(
                shopID: shop.id, workflowID: workflowID,
                state: .unsupported(
                    "This merchant does not currently offer UCP checkout in Crumb.",
                    fallbackURL: fallback
                )
            )
        } catch UCPError.emptyCheckout(_) {
            updateCheckout(
                shopID: shop.id, workflowID: workflowID,
                state: .failed("No checkout items were accepted by this merchant. Your cart is unchanged.")
            )
        } catch {
            updateCheckout(
                shopID: shop.id, workflowID: workflowID,
                state: .failed("Checkout could not be prepared. Your cart is unchanged.")
            )
        }
    }

    private func updateCheckout(shopID: Shop.ID, workflowID: UUID, state: MerchantCheckout.State) {
        guard var workflow = checkoutWorkflow, workflow.id == workflowID,
              let index = workflow.merchants.firstIndex(where: { $0.shop.id == shopID }) else { return }
        workflow.merchants[index].state = state
        checkoutWorkflow = workflow
    }

    func editSandboxCheckout(for shop: Shop, _ edit: (inout SandboxCheckout) -> Void) {
        guard let workflowID = checkoutWorkflow?.id else { return }
        updateSandbox(shopID: shop.id, workflowID: workflowID) { sandbox in
            guard var value = sandbox else { return }
            edit(&value)
            sandbox = value
        }
    }

    func submitSandboxContact(for shop: Shop) async {
        guard let workflow = checkoutWorkflow,
              let merchant = workflow.merchants.first(where: { $0.id == shop.id }),
              case .prepared(let session) = merchant.state,
              var sandbox = merchant.sandbox,
              (sandbox.phase == .contact || sandbox.phase == .shipping || sandbox.phase == .review),
              sandbox.canSubmitContact else { return }
        let key = sandbox.updateKey ?? "crumb-update-\(UUID().uuidString)"
        sandbox.updateKey = key
        sandbox.phase = .updating
        setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        let selections = sandbox.shippingSelections.map {
            CheckoutFulfillmentSelection(groupID: $0.key, optionID: $0.value)
        }
        let command = CheckoutUpdateCommand(
            buyer: CheckoutBuyer(firstName: sandbox.firstName, lastName: sandbox.lastName,
                                  email: sandbox.email, phoneNumber: sandbox.phone.isEmpty ? nil : sandbox.phone),
            shippingAddress: CheckoutPostalAddress(
                firstName: sandbox.firstName, lastName: sandbox.lastName,
                streetAddress: sandbox.street, extendedAddress: nil, locality: sandbox.city,
                region: sandbox.region, postalCode: sandbox.postalCode, country: sandbox.country,
                phoneNumber: sandbox.phone.isEmpty ? nil : sandbox.phone),
            selections: selections
        )
        do {
            let updated = try await ucp.updateCheckout(id: session.id, update: command, idempotencyKey: key)
            updateCheckout(shopID: shop.id, workflowID: workflow.id, state: .prepared(updated))
            sandbox.phase = updated.status == .readyForComplete ? .review : .shipping
            sandbox.shippingSelections = Dictionary(uniqueKeysWithValues: updated.fulfillmentGroups.compactMap {
                guard let selected = $0.selectedOptionID ?? $0.options.first?.id else { return nil }
                return ($0.id, selected)
            })
            // A newly surfaced default is a new payload; the explicit shipping update gets its own
            // idempotency key while an unchanged retry continues to reuse that new key.
            if updated.fulfillmentGroups.contains(where: { $0.selectedOptionID == nil }) {
                sandbox.updateKey = nil
            }
            sandbox.authoritativeFingerprint = updated.status == .readyForComplete ? sandbox.fingerprint : nil
            sandbox.acknowledgedFingerprint = nil
            setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        } catch UCPError.checkoutExpired {
            sandbox.phase = .expired
            setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        } catch {
            sandbox.phase = .failed("Sandbox checkout could not be updated. Try again.")
            setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        }
    }

    func completeSandboxCheckout(for shop: Shop) async {
        guard let workflow = checkoutWorkflow,
              let merchant = workflow.merchants.first(where: { $0.id == shop.id }),
              case .prepared(let session) = merchant.state,
              case .sandbox(let handlerID) = session.provenance,
              handlerID == CheckoutCompletionAuthorization.crumbSandboxPay.handlerInstanceID,
              var sandbox = merchant.sandbox,
              session.status == .readyForComplete,
              sandbox.phase == .review, !sandbox.isDirty, sandbox.isAcknowledged,
              authoritativeSelections(in: session) == sandbox.shippingSelections else { return }
        let key = sandbox.completionKey ?? "crumb-complete-\(UUID().uuidString)"
        sandbox.completionKey = key
        sandbox.phase = .completing
        setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        do {
            let completed = try await ucp.completeCheckout(
                id: session.id, authorization: .crumbSandboxPay, idempotencyKey: key)
            updateCheckout(shopID: shop.id, workflowID: workflow.id, state: .prepared(completed))
            sandbox.phase = .completed
            setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
            if checkoutWorkflow?.merchants.allSatisfy({ $0.sandbox?.phase == .completed }) == true {
                mutateActiveThread {
                    $0.phase = .completed
                    $0.appendEvent(kind: .notice, text: "Checkout completed for every shop.", createdAt: clock())
                }
            }
        } catch UCPError.checkoutExpired {
            sandbox.phase = .expired
            setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        } catch {
            sandbox.phase = .failed("Sandbox completion is uncertain. Refresh or start a fresh sandbox checkout before trying again.")
            setSandbox(sandbox, shopID: shop.id, workflowID: workflow.id)
        }
    }

    func retrySandboxCheckout(for shop: Shop) async {
        editSandboxCheckout(for: shop) { sandbox in
            sandbox.phase = sandbox.completionKey == nil ? .contact : .review
        }
    }

    func acknowledgeSandboxReview(for shop: Shop, acknowledged: Bool) {
        editSandboxCheckout(for: shop) {
            $0.acknowledgedFingerprint = acknowledged ? $0.fingerprint : nil
        }
    }

    func mutateSandboxPayload(for shop: Shop, _ edit: (inout SandboxCheckout) -> Void) {
        editSandboxCheckout(for: shop) {
            edit(&$0)
            $0.updateKey = nil
            $0.acknowledgedFingerprint = nil
        }
    }

    func startFreshSandboxCheckout(for shop: Shop) async {
        guard let merchant = checkoutWorkflow?.merchants.first(where: { $0.id == shop.id }) else { return }
        let items = merchant.items
        closeCheckoutWorkflow()
        guard !items.isEmpty else { return }
        let workflowID = UUID()
        checkoutWorkflow = CheckoutWorkflow(id: workflowID, merchants: [MerchantCheckout(
            shop: shop, items: items, idempotencyKey: "crumb-\(UUID().uuidString)",
            state: .preparing, sandbox: nil
        )])
        await prepareCheckout(for: shop, in: Cart(items: items), workflowID: workflowID)
    }

    func closeCheckoutWorkflow() {
        guard let workflow = checkoutWorkflow else { return }
        let sandboxIDs = workflow.merchants.compactMap { merchant -> String? in
            guard case .prepared(let session) = merchant.state,
                  case .sandbox = session.provenance else { return nil }
            return session.id
        }
        checkoutWorkflow = nil // immediately releases all transient buyer/address data
        Task { for id in sandboxIDs { try? await ucp.discardCheckout(id: id) } }
    }

    private func authoritativeSelections(in session: CheckoutSession) -> [String: String] {
        Dictionary(uniqueKeysWithValues: session.fulfillmentGroups.compactMap {
            guard let selected = $0.selectedOptionID else { return nil }
            return ($0.id, selected)
        })
    }

    private func updateSandbox(
        shopID: Shop.ID, workflowID: UUID,
        edit: (inout SandboxCheckout?) -> Void
    ) {
        guard var workflow = checkoutWorkflow, workflow.id == workflowID,
              let index = workflow.merchants.firstIndex(where: { $0.id == shopID }) else { return }
        edit(&workflow.merchants[index].sandbox)
        checkoutWorkflow = workflow
    }

    private func setSandbox(_ sandbox: SandboxCheckout, shopID: Shop.ID, workflowID: UUID) {
        updateSandbox(shopID: shopID, workflowID: workflowID) { $0 = sandbox }
    }

    /// Resolves the per-shop UCP handoff URL and presents the handoff sheet.
    ///
    /// The sheet is *always* presented so the "Continue" tap is never a silent no-op: if
    /// no handoff target can be resolved (no `continue_url`, no merchant domain, or the
    /// broker errors) the handoff carries a `nil` url and the sheet says so plainly.
    func beginHandoff(for shop: Shop) async {
        let cart = currentCart
        let url = try? await ucp.checkoutHandoff(for: shop, in: cart)
        handoff = Handoff(shop: shop, url: url, items: cart.items(for: shop))
    }

    /// Hands off a **single** shortlisted product — the "Buy this" action in the single-product
    /// compare-and-buy cart (#60). Resolves the handoff against a one-item cart so the user checks
    /// out exactly that product, even if another shortlisted option happens to share its shop.
    func beginHandoff(for item: KitItem) async {
        let oneItemCart = Cart(items: [item])
        let url = try? await ucp.checkoutHandoff(for: item.product.shop, in: oneItemCart)
        handoff = Handoff(shop: item.product.shop, url: url, items: [item])
    }
}
