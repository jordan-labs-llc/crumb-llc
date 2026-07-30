import Foundation

/// One stable, editable line in a mission's plan.
///
/// Unlike the app's original ephemeral `PlanPart`, the identity is durable so a resumed thread can
/// keep SwiftUI identity, accessibility focus, and edits attached to the same part.
public struct MissionPlanPart: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var label: String
    public var query: String

    public init(id: String = UUID().uuidString, label: String, query: String) {
        self.id = id
        self.label = label
        self.query = query
    }
}

/// The durable state machine for one mission workspace.
public enum MissionThreadPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case planning
    case planReady
    case gathering
    case deckReady
    case failed
    case declined
    case completed
    case abandoned
}

/// Semantic timeline kinds. These are deliberately application-level events rather than raw model
/// transcript entries: prompts, tool JSON, reasoning, and partial streamed text never reach disk.
public enum MissionThreadEventKind: String, Hashable, Sendable, Codable, CaseIterable {
    case userMessage
    case assistantMessage
    case planningStarted
    case planReady
    case gatheringStarted
    case productsFound
    case gatheringCompleted
    case refinementRequested
    case refinementApplied
    case refinementsReset
    case productAdded
    case productSkipped
    case productRemoved
    case variantChanged
    case cartOpened
    case failure
    case interrupted
    case notice
}

/// One user-visible line in a mission thread's semantic timeline.
public struct MissionThreadEvent: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let sequence: Int
    public let kind: MissionThreadEventKind
    public let text: String
    public let createdAt: Date
    public let productID: Product.ID?
    public let operationID: String?
    /// Reset keeps old refinement turns visible, but marks them as excluded from active context.
    public var isSuperseded: Bool
    /// Frozen, read-only content rendered beneath this turn. Commerce mutations always resolve
    /// against authoritative thread state, never by replaying or parsing these display snapshots.
    public let blocks: [MissionMessageBlock]
    /// For a user turn: the id of the option they *tapped*, or `nil` if they typed.
    ///
    /// The distinction is not decoration. A tapped chip's text is Crumb's own label echoed back, and
    /// its consequence is always visible in what followed — so a UI can decline to read the label a
    /// second time. Typed prose is the person's own words, which nothing else in the timeline
    /// preserves, and must always be shown. Recording the id (not just "was a choice") also keeps the
    /// answer legible in the record after a label is reworded.
    public let chosenOptionID: String?

    public init(
        id: String = UUID().uuidString,
        sequence: Int,
        kind: MissionThreadEventKind,
        text: String,
        createdAt: Date,
        productID: Product.ID? = nil,
        operationID: String? = nil,
        isSuperseded: Bool = false,
        blocks: [MissionMessageBlock] = [],
        chosenOptionID: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.productID = productID
        self.operationID = operationID
        self.isSuperseded = isSuperseded
        self.blocks = blocks
        self.chosenOptionID = chosenOptionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, sequence, kind, text, createdAt, productID, operationID, isSuperseded, blocks
        case chosenOptionID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sequence = try values.decode(Int.self, forKey: .sequence)
        kind = try values.decode(MissionThreadEventKind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        productID = try values.decodeIfPresent(Product.ID.self, forKey: .productID)
        operationID = try values.decodeIfPresent(String.self, forKey: .operationID)
        isSuperseded = try values.decodeIfPresent(Bool.self, forKey: .isSuperseded) ?? false
        blocks = try values.decodeIfPresent([MissionMessageBlock].self, forKey: .blocks) ?? []
        // Absent on every thread persisted before choices were distinguished from typed prose. Those
        // turns decode as "typed", which is the safe direction: a rendered echo is redundant, a
        // dropped sentence would be lost words.
        chosenOptionID = try values.decodeIfPresent(String.self, forKey: .chosenOptionID)
    }
}

// MARK: - Frozen conversation content

public struct MissionPlanSnapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let revision: Int
    public let title: String
    public let parts: [MissionPlanPart]

    public init(id: String, revision: Int, title: String, parts: [MissionPlanPart]) {
        self.id = id
        self.revision = revision
        self.title = title
        self.parts = parts
    }
}

public struct MissionProductSnapshot: Hashable, Sendable, Codable {
    public let productID: Product.ID
    public let variantID: Variant.ID?
    public let title: String
    public let merchant: String
    public let imageURL: URL?
    public let presentedPrice: Decimal
    public let presentedAvailability: String
    public let variantTitle: String?
    public let rationale: String
    public let disclosure: String?

    public init(
        productID: Product.ID,
        variantID: Variant.ID? = nil,
        title: String,
        merchant: String,
        imageURL: URL? = nil,
        presentedPrice: Decimal,
        presentedAvailability: String = "Available when shown",
        variantTitle: String? = nil,
        rationale: String,
        disclosure: String? = nil
    ) {
        self.productID = productID
        self.variantID = variantID
        self.title = title
        self.merchant = merchant
        self.imageURL = imageURL
        self.presentedPrice = presentedPrice
        self.presentedAvailability = presentedAvailability
        self.variantTitle = variantTitle
        self.rationale = rationale
        self.disclosure = disclosure
    }

    /// Whether this can legally be frozen into a turn. See ``MissionComparisonSnapshot/isPresentable``.
    public var isPresentable: Bool {
        !productID.isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && presentedPrice >= 0
    }

    public init(product: Product, variant: Variant? = nil, availability: String = "Available when shown", disclosure: String? = nil) {
        self.init(
            productID: product.id,
            variantID: variant?.id,
            title: product.name,
            merchant: product.shop.name,
            imageURL: product.imageURL,
            presentedPrice: variant?.price ?? product.price,
            presentedAvailability: availability,
            variantTitle: variant?.title,
            rationale: product.rationale,
            disclosure: disclosure
        )
    }
}

public struct MissionComparisonSnapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let products: [MissionProductSnapshot]
    public init(id: String, products: [MissionProductSnapshot]) {
        self.id = id
        self.products = products
    }

    /// Whether this can legally be frozen into a turn — the same invariants ``MissionThread``
    /// enforces when it validates the document.
    ///
    /// Exposed so a *presentation* choice can be tested before it is committed. A block that fails
    /// validation makes the whole enclosing `mutateActiveThread` transaction roll back, so an
    /// unpresentable comparison does not merely fail to render: it silently destroys the commerce
    /// mutation it was appended alongside. Callers check this and fall back to a single product.
    public var isPresentable: Bool {
        guard !id.isEmpty, (2...4).contains(products.count) else { return false }
        guard products.allSatisfy(\.isPresentable) else { return false }
        return Set(products.map(\.productID)).count == products.count
    }
}

public struct MissionKitSnapshotItem: Identifiable, Hashable, Sendable, Codable {
    public var id: Product.ID { productID }
    public let productID: Product.ID
    public let variantID: Variant.ID
    public let title: String
    public let variantTitle: String
    public let merchant: String
    public let presentedPrice: Decimal

    public init(item: KitItem) {
        productID = item.product.id
        variantID = item.variant.id
        title = item.product.name
        variantTitle = item.variant.title
        merchant = item.product.shop.name
        presentedPrice = item.variant.price
    }
}

public struct MissionKitSnapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let revision: Int
    public let items: [MissionKitSnapshotItem]
    public init(id: String, revision: Int, items: [MissionKitSnapshotItem]) {
        self.id = id
        self.revision = revision
        self.items = items
    }
}

public struct MissionActivityReceipt: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let operationID: String?
    public let title: String
    public let detail: String?
    public init(id: String = UUID().uuidString, operationID: String? = nil, title: String, detail: String? = nil) {
        self.id = id
        self.operationID = operationID
        self.title = title
        self.detail = detail
    }
}

/// One line of an auto-keep receipt: what Crumb kept, and which part of the plan it was for.
public struct MissionAutoKeepRow: Identifiable, Hashable, Sendable, Codable {
    public var id: Product.ID { productID }
    public let productID: Product.ID
    public let title: String
    public let merchant: String
    public let presentedPrice: Decimal
    /// The plan part this pick covered — the reason it was the one taken. `nil` when the mission
    /// had no checklist to answer to.
    public let part: String?

    public init(
        productID: Product.ID,
        title: String,
        merchant: String,
        presentedPrice: Decimal,
        part: String? = nil
    ) {
        self.productID = productID
        self.title = title
        self.merchant = merchant
        self.presentedPrice = presentedPrice
        self.part = part
    }
}

/// What Crumb did on its own during one pass of ``MissionApprovalMode/auto``.
///
/// This is the *receipt*, not a progress log: it exists because those decisions happened without the
/// person in the loop, so it is the only place the outcome can be attributed and reversed. A mission
/// in `askEach` never produces one, which is why nothing about the default experience changes.
public struct MissionAutoKeepSnapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// The picks Crumb kept, in the order it kept them.
    public let kept: [MissionAutoKeepRow]
    /// Picks auto deliberately refused and left on the deck for the person, with `heldBackReason`
    /// naming why. Empty on an unremarkable pass.
    public let heldBack: [MissionAutoKeepRow]
    public let heldBackReason: String?

    public init(
        id: String,
        kept: [MissionAutoKeepRow],
        heldBack: [MissionAutoKeepRow] = [],
        heldBackReason: String? = nil
    ) {
        self.id = id
        self.kept = kept
        self.heldBack = heldBack
        self.heldBackReason = heldBackReason
    }
}

public enum MissionMessageBlock: Hashable, Sendable, Codable {
    case text(String)
    case plan(MissionPlanSnapshot)
    case product(MissionProductSnapshot)
    case comparison(MissionComparisonSnapshot)
    case kit(MissionKitSnapshot)
    case activity(MissionActivityReceipt)
    case autoKeep(MissionAutoKeepSnapshot)
}

/// The reversal auto-keep leaves behind: everything Crumb has kept on its own that the person has
/// not yet answered for.
///
/// Held on the aggregate rather than derived from the timeline because undo has to restore *state* —
/// kit membership, decisions, deck order — and reconstructing that by parsing a display snapshot is
/// exactly what the thread's frozen blocks are forbidden from being used for.
///
/// It spans passes rather than tracking only the latest one. A refinement can settle straight into a
/// second pass before the first has been acknowledged, and a chip reading "Undo those 2" that
/// silently leaves three earlier picks in the kit is worse than no chip at all.
public struct MissionAutoKeepUndo: Hashable, Sendable, Codable {
    /// Every receipt this reversal covers, oldest first — the turns to mark reversed when it is taken.
    public let receiptIDs: [String]
    /// The decision ids written by those passes — the handles onto both the kit items and the record.
    public let decisionIDs: [String]
    public let productIDs: [Product.ID]

    public init(receiptIDs: [String], decisionIDs: [String], productIDs: [Product.ID]) {
        self.receiptIDs = receiptIDs
        self.decisionIDs = decisionIDs
        self.productIDs = productIDs
    }

    /// Folds a fresh pass into an outstanding one, preserving order and never double-counting.
    public func merging(_ other: MissionAutoKeepUndo) -> MissionAutoKeepUndo {
        func appended(_ base: [String], _ new: [String]) -> [String] {
            var seen = Set(base)
            return base + new.filter { seen.insert($0).inserted }
        }
        return MissionAutoKeepUndo(
            receiptIDs: appended(receiptIDs, other.receiptIDs),
            decisionIDs: appended(decisionIDs, other.decisionIDs),
            productIDs: appended(productIDs, other.productIDs)
        )
    }
}

// MARK: - Durable interaction protocol

public enum MissionInteractionKind: String, Hashable, Sendable, Codable, CaseIterable {
    case clarification
    case planApproval
    case productDecision
    case variantSelection
    case retry
    case cartReview
    case refinement
    case recovery
}

public enum MissionSelectionMode: String, Hashable, Sendable, Codable, CaseIterable {
    case singleChoice
    case confirmation
}

public struct MissionInteractionOption: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let label: String
    public let detail: String?
    /// This option ends the mission. Carried on the durable option rather than derived from its id
    /// in a view, because the presentation rule is a property of the *command*: surfaces demote
    /// these out of the row of peer chips and confirm before submitting. It costs no option slot,
    /// so the four-option interaction cap is untouched.
    public let isDestructive: Bool

    public init(id: String, label: String, detail: String? = nil, isDestructive: Bool = false) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isDestructive = isDestructive
    }

    /// Options persisted before this flag existed decode as non-destructive instead of throwing.
    /// A decode failure here would quarantine the entire thread over a presentation hint.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isDestructive = try container.decodeIfPresent(Bool.self, forKey: .isDestructive) ?? false
    }
}

/// Persistable command identity for one question. Labels and assistant prose are never parsed to
/// recreate this context.
public enum MissionInteractionResolver: Hashable, Sendable, Codable {
    case clarification(contextID: String)
    case plan(planRevision: Int)
    case product(productID: Product.ID, variantID: Variant.ID?)
    case retry(MissionRetryDescriptor)
    case kit(snapshotID: String, revision: Int)
    case refinement(baseRevision: Int)
}

public struct MissionPendingInteraction: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let promptEventID: String
    public let interactionGeneration: Int
    public let subjectRevision: Int
    public let kind: MissionInteractionKind
    public let question: String
    public let options: [MissionInteractionOption]
    public let selectionMode: MissionSelectionMode
    public let allowsFreeText: Bool
    public let resolver: MissionInteractionResolver
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        promptEventID: String,
        interactionGeneration: Int,
        subjectRevision: Int,
        kind: MissionInteractionKind,
        question: String,
        options: [MissionInteractionOption],
        selectionMode: MissionSelectionMode,
        allowsFreeText: Bool,
        resolver: MissionInteractionResolver,
        createdAt: Date
    ) {
        self.id = id
        self.promptEventID = promptEventID
        self.interactionGeneration = interactionGeneration
        self.subjectRevision = subjectRevision
        self.kind = kind
        self.question = question
        self.options = options
        self.selectionMode = selectionMode
        self.allowsFreeText = allowsFreeText
        self.resolver = resolver
        self.createdAt = createdAt
    }
}

public enum MissionInteractionAnswer: Hashable, Sendable, Codable {
    case option(id: String)
    case freeText(String)
}

public struct MissionInteractionSubmission: Hashable, Sendable, Codable {
    public let threadID: String
    public let interactionID: String
    public let interactionGeneration: Int
    public let subjectRevision: Int
    public let idempotencyID: String
    public let answer: MissionInteractionAnswer

    public init(threadID: String, interactionID: String, interactionGeneration: Int, subjectRevision: Int, idempotencyID: String = UUID().uuidString, answer: MissionInteractionAnswer) {
        self.threadID = threadID
        self.interactionID = interactionID
        self.interactionGeneration = interactionGeneration
        self.subjectRevision = subjectRevision
        self.idempotencyID = idempotencyID
        self.answer = answer
    }
}

public enum MissionBlockingRecovery: Hashable, Sendable, Codable {
    case savePendingInteraction(failedRevision: Int)
    case saveCommittedMutation(failedRevision: Int, idempotencyID: String)
}

public enum MissionInteractionSubmissionError: Error, Hashable, Sendable {
    case wrongThread
    case noPendingInteraction
    case staleInteraction
    case staleGeneration(expected: Int, received: Int)
    case staleSubject(expected: Int, received: Int)
    case unknownOption(String)
    case freeTextNotAllowed
    case blankFreeText
    case blockedByRecovery
    case blankIdempotencyID
    case reusedIdempotencyID(String)
}

/// The asynchronous operation classes that need a per-thread epoch guard.
public enum MissionOperationKind: String, Hashable, Sendable, Codable, CaseIterable {
    case planning
    case gathering
    case curation
    case refinement
    case chips
}

/// Structured retry data. User-facing retry behavior never parses a timeline sentence.
public struct MissionRetryDescriptor: Hashable, Sendable, Codable {
    public let kind: MissionOperationKind
    /// Planning goal or refinement text. Gathering/curation can leave this empty and use the task.
    public let input: String
    /// The task/plan revision the operation was based on, when applicable.
    public let taskRevision: Int?
    /// The last stable phase the retry may return to or restore on interruption.
    public let returnPhase: MissionThreadPhase

    public init(
        kind: MissionOperationKind,
        input: String = "",
        taskRevision: Int? = nil,
        returnPhase: MissionThreadPhase
    ) {
        self.kind = kind
        self.input = input
        self.taskRevision = taskRevision
        self.returnPhase = returnPhase
    }
}

/// A durable marker for work that was in flight when a process stopped.
///
/// `Task` handles and spinner flags remain runtime-only. This small descriptor is enough to turn an
/// interrupted launch into an actionable retry without replaying a search or write side effect.
public struct MissionPendingOperation: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let retry: MissionRetryDescriptor
    public let startedAt: Date

    public init(
        id: String = UUID().uuidString,
        retry: MissionRetryDescriptor,
        startedAt: Date
    ) {
        self.id = id
        self.retry = retry
        self.startedAt = startedAt
    }
}

/// Who made a decision — the person, or Crumb acting on delegated authority.
///
/// Recorded on the decision rather than inferred from the timeline, because once Crumb can keep
/// things on its own the two are otherwise indistinguishable in the record: a kit assembled under
/// ``MissionApprovalMode/auto`` and one assembled a tap at a time produce byte-identical `kit`
/// arrays. "Which of these did I actually approve?" has to remain answerable.
public enum MissionDecider: String, Hashable, Sendable, Codable, CaseIterable {
    case person
    case crumb
}

/// A deterministic product decision kept alongside the snapshot.
public struct MissionProductDecision: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case added
        case skipped
        case removed
        case variantChanged
    }

    /// The idempotency identity. Reusing it must not apply or narrate an operation twice.
    public let id: String
    public let kind: Kind
    public let productID: Product.ID
    public let variantID: Variant.ID?
    public let createdAt: Date
    /// Optional so every decision persisted before delegation existed decodes unchanged. `nil` reads
    /// as ``MissionDecider/person`` — every one of them was a tap — and surfaces treat it that way,
    /// so absence can never mis-attribute a human decision to Crumb.
    public let decidedBy: MissionDecider?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        productID: Product.ID,
        variantID: Variant.ID? = nil,
        createdAt: Date,
        decidedBy: MissionDecider? = nil
    ) {
        self.id = id
        self.kind = kind
        self.productID = productID
        self.variantID = variantID
        self.createdAt = createdAt
        self.decidedBy = decidedBy
    }

    /// True only when Crumb decided this one itself.
    public var wasDecidedByCrumb: Bool { decidedBy == .crumb }
}

/// How much a mission asks before it keeps something.
///
/// The status quo is ``askEach``: every candidate is its own blocking question, so a five-part kit is
/// five sequential decisions before anything can be reviewed. ``auto`` delegates the obvious half of
/// that — one keep per plan part the kit doesn't cover yet — and reports it as a single reversible
/// receipt. It is per-mission, not a global setting: delegation is a judgement about *this* errand.
///
/// What `auto` may never do is as much of the definition as what it may. It only ever moves in the
/// keep direction (a skip is a decision too, and a passed-over card stays on the deck), it never
/// answers a cart, retry, recovery or refinement question, it never chooses a destructive option, and
/// it never opens the cart or starts a checkout. Money leaving the mission stays a human tap in every
/// mode.
public enum MissionApprovalMode: String, Hashable, Sendable, Codable, CaseIterable {
    case askEach
    case auto
}

/// Why a decoded mission document cannot safely become an actionable workspace.
public enum MissionThreadValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    case blankID
    case blankGoal
    case invalidRevision(Int)
    case invalidInteractionGeneration(Int)
    case conflictingPlanID(String)
    case conflictingProductID(String)
    case unresolvedDeckProduct(String)
    case duplicateKitProduct(String)
    case invalidKitVariant(productID: String, variantID: String)
    case duplicateDecisionID(String)
    case unresolvedDecisionProduct(String)
    case duplicateTimelineID(String)
    case duplicateTimelineSequence(Int)
    case invalidInteraction(String)
    case unresolvedInteractionPrompt(String)
    case unresolvedInteractionProduct(String)
    case unresolvedInteractionVariant(productID: String, variantID: String)
    case unresolvedInteractionSnapshot(String)
    case invalidPhase(MissionThreadPhase, reason: String)

    public var description: String {
        switch self {
        case .blankID: return "The thread id is blank."
        case .blankGoal: return "The original mission goal is blank."
        case .invalidRevision(let value): return "The thread revision \(value) is invalid."
        case .invalidInteractionGeneration(let value): return "The interaction generation \(value) is invalid."
        case .conflictingPlanID(let id): return "Plan id \(id) maps to conflicting parts."
        case .conflictingProductID(let id): return "Product id \(id) maps to conflicting snapshots."
        case .unresolvedDeckProduct(let id): return "Deck product \(id) is missing from candidates."
        case .duplicateKitProduct(let id): return "The kit contains product \(id) more than once."
        case let .invalidKitVariant(productID, variantID):
            return "Variant \(variantID) does not belong to kit product \(productID)."
        case .duplicateDecisionID(let id): return "Decision operation \(id) is duplicated."
        case .unresolvedDecisionProduct(let id): return "Decision product \(id) is not known to the thread."
        case .duplicateTimelineID(let id): return "Timeline id \(id) is duplicated."
        case .duplicateTimelineSequence(let sequence): return "Timeline sequence \(sequence) is duplicated."
        case .invalidInteraction(let reason): return "The pending interaction is invalid: \(reason)"
        case .unresolvedInteractionPrompt(let id): return "Interaction prompt event \(id) is missing."
        case .unresolvedInteractionProduct(let id): return "Interaction product \(id) is not known to the thread."
        case let .unresolvedInteractionVariant(productID, variantID):
            return "Interaction variant \(variantID) does not belong to product \(productID)."
        case .unresolvedInteractionSnapshot(let id): return "Interaction snapshot \(id) is missing."
        case let .invalidPhase(phase, reason): return "Phase \(phase.rawValue) is invalid: \(reason)"
        }
    }
}

/// The authoritative, durable snapshot for one conversation-backed shopping mission.
///
/// The timeline explains successful mutations but is never replayed to rebuild this value. Products,
/// plan, deck order, kit, recipient, and refinement context live here exactly once.
public struct MissionThread: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var revision: Int
    public let originalGoal: String
    public var goal: String
    public var phase: MissionThreadPhase
    public var task: ShoppingTask?
    public var plan: [MissionPlanPart]
    public var candidates: [Product]
    public var baseCandidates: [Product]
    public var remainingDeckIDs: [Product.ID]
    public var kit: [KitItem]
    public var decisions: [MissionProductDecision]
    public var refinementTurns: [String]
    public var refinementDirectives: [RefinementDirective]
    /// Free text the user sent while a gather was still searching, held to run as a refinement
    /// the moment the deck settles — so typing "under $50" mid-search never cancels the search
    /// or wedges an empty deck. Optional so threads persisted before this field decode
    /// unchanged (`nil` == none queued).
    public var queuedRefinements: [String]?
    /// Which search found each candidate, as the gather reported it — a plan part's label for a
    /// planned search, the model's own query for one it reached for beyond the plan.
    ///
    /// Held as a map beside the candidates rather than as a field on ``Product`` so the product
    /// shape — and every mission snapshot already persisted through it in History — stays untouched.
    /// Optional so threads written before the gather recorded provenance decode unchanged; `nil` and
    /// an empty map both mean "nothing was attributed", which ``part(of:)`` reads as not knowing.
    public var candidateParts: [Product.ID: String]?
    /// How much this mission asks before keeping something. Optional so every thread persisted before
    /// delegation existed decodes unchanged; `nil` reads as ``MissionApprovalMode/askEach``, which is
    /// exactly what those threads did.
    public var approvalMode: MissionApprovalMode?
    /// The reversal offered on the question immediately after an auto-keep pass, and only there.
    public var pendingAutoKeepUndo: MissionAutoKeepUndo?
    /// Full immutable-at-mission-start snapshot; its id still lets AppModel target a live roster edit.
    public var recipient: Recipient?
    public var tasteSnapshot: TasteProfile
    public var pendingOperation: MissionPendingOperation?
    public var retry: MissionRetryDescriptor?
    /// Monotonic question epoch. It changes only when a question is created, answered,
    /// superseded, or invalidated; unrelated thread revisions do not change it.
    public var interactionGeneration: Int
    public var pendingInteraction: MissionPendingInteraction?
    public var blockingRecovery: MissionBlockingRecovery?
    public var timeline: [MissionThreadEvent]
    /// Optional scalar link only. History and the thread never cascade or require each other to decode.
    public var historyEntryID: String?
    public let createdAt: Date
    public var updatedAt: Date

    /// Starts a durable thread before planning, so even planning failure/decline is resumable.
    public init(
        id: String = UUID().uuidString,
        goal: String,
        recipient: Recipient? = nil,
        taste: TasteProfile,
        now: Date = Date()
    ) {
        self.init(
            id: id,
            revision: 0,
            originalGoal: goal,
            goal: goal,
            phase: .planning,
            task: nil,
            plan: [],
            candidates: [],
            baseCandidates: [],
            remainingDeckIDs: [],
            kit: [],
            decisions: [],
            refinementTurns: [],
            refinementDirectives: [],
            recipient: recipient,
            tasteSnapshot: taste,
            pendingOperation: nil,
            retry: nil,
            interactionGeneration: 0,
            pendingInteraction: nil,
            blockingRecovery: nil,
            timeline: [],
            historyEntryID: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    public init(
        id: String,
        revision: Int,
        originalGoal: String,
        goal: String,
        phase: MissionThreadPhase,
        task: ShoppingTask?,
        plan: [MissionPlanPart],
        candidates: [Product],
        baseCandidates: [Product],
        remainingDeckIDs: [Product.ID],
        kit: [KitItem],
        decisions: [MissionProductDecision],
        refinementTurns: [String],
        refinementDirectives: [RefinementDirective],
        queuedRefinements: [String]? = nil,
        candidateParts: [Product.ID: String]? = nil,
        approvalMode: MissionApprovalMode? = nil,
        pendingAutoKeepUndo: MissionAutoKeepUndo? = nil,
        recipient: Recipient?,
        tasteSnapshot: TasteProfile,
        pendingOperation: MissionPendingOperation?,
        retry: MissionRetryDescriptor?,
        interactionGeneration: Int = 0,
        pendingInteraction: MissionPendingInteraction? = nil,
        blockingRecovery: MissionBlockingRecovery? = nil,
        timeline: [MissionThreadEvent],
        historyEntryID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.revision = revision
        self.originalGoal = originalGoal
        self.goal = goal
        self.phase = phase
        self.task = task
        self.plan = plan
        self.candidates = candidates
        self.baseCandidates = baseCandidates
        self.remainingDeckIDs = remainingDeckIDs
        self.kit = kit
        self.decisions = decisions
        self.refinementTurns = refinementTurns
        self.refinementDirectives = refinementDirectives
        self.queuedRefinements = queuedRefinements
        self.candidateParts = candidateParts
        self.approvalMode = approvalMode
        self.pendingAutoKeepUndo = pendingAutoKeepUndo
        self.recipient = recipient
        self.tasteSnapshot = tasteSnapshot
        self.pendingOperation = pendingOperation
        self.retry = retry
        self.interactionGeneration = interactionGeneration
        self.pendingInteraction = pendingInteraction
        self.blockingRecovery = blockingRecovery
        self.timeline = timeline
        self.historyEntryID = historyEntryID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var nextTimelineSequence: Int { (timeline.map(\.sequence).max() ?? -1) + 1 }

    public var remainingDeck: [Product] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return remainingDeckIDs.compactMap { byID[$0] }
    }

    /// Which part of this mission `product` belongs to, or `nil` when nothing can place it.
    /// See ``MissionPartAttribution`` for how the plan's words and the gather's provenance combine.
    public func part(of product: Product) -> String? {
        MissionPartAttribution.part(
            of: product, plan: plan.map(\.label), provenance: candidateParts?[product.id]
        )
    }

    /// The remaining candidates that are genuine alternatives to `product` — same part, still
    /// undecided, in the deck's ranked order.
    ///
    /// A **single-item** mission skips the question: its whole deck is one apples-to-apples set by
    /// definition, and a catalog that names things nothing like the goal does ("Dragon Pearl" for a
    /// jasmine mission) would otherwise strand a perfectly comparable deck with no alternatives.
    ///
    /// A kit mission also needs its attribution to actually divide the pool before any of it can be
    /// read as a comparison — see ``MissionPartAttribution/isPartitioned(_:plan:provenance:)``.
    public func alternatives(to product: Product) -> [Product] {
        let deck = remainingDeck
        guard task?.isSingleItem != true else { return deck.filter { $0.id != product.id } }
        let labels = plan.map(\.label)
        let provenance = candidateParts ?? [:]
        guard MissionPartAttribution.isPartitioned(candidates, plan: labels, provenance: provenance)
        else { return [] }
        return MissionPartAttribution.peers(
            of: product, among: deck, plan: labels, provenance: provenance
        )
    }

    /// The next candidate to ask about: the best remaining one for the **first plan part the kit
    /// doesn't cover yet**, so a multi-part errand is walked a part at a time with the kit filling in
    /// behind, rather than down a globally fit-ranked union that hops between parts.
    ///
    /// Within a part the deck's own order is kept — the ranking is the curator's, and this only
    /// chooses which part is being answered. It falls back to plain deck order whenever sequencing
    /// has nothing to say: a single-item mission, a mission with too few parts to divide up, or an
    /// open part with nothing left on the deck to offer for it (so a part nobody can shop for cannot
    /// stall the mission).
    ///
    /// `readsRationale: false` for the same reason ``MissionAutoKeep`` uses it: the deterministic
    /// curator's sentence names every part of the mission on every card, so reading it would report
    /// the checklist complete after one keep.
    public var nextCard: Product? { nextCard(passingOver: nil) }

    /// ``nextCard`` with one card set aside — what "Show another" needs. Without it, sequencing and
    /// rotation fight: the rotated card is still the best answer to the open part, so it would be
    /// pulled straight back to the front and the offer would do nothing.
    ///
    /// The set-aside card is still returned when it is all that is left, so a lone candidate is
    /// re-offered rather than the mission jumping to its kit with cards undecided.
    public func nextCard(passingOver skipped: Product.ID?) -> Product? {
        let deck = remainingDeck.filter { $0.id != skipped }
        guard !deck.isEmpty else { return remainingDeck.first }
        let labels = plan.map(\.label)
        guard task?.isSingleItem != true, labels.count >= MissionAutoKeep.minimumParts else {
            return deck.first
        }
        let open = KitCompleteness.assess(
            plan: labels, items: kit.map(\.product), readsRationale: false
        ).missing
        for part in open {
            if let next = deck.first(where: { self.part(of: $0) == part }) { return next }
        }
        return deck.first
    }

    /// The product the standing question is about, when it is a question about a product.
    public var pendingProductID: Product.ID? {
        guard case .product(let id, _) = pendingInteraction?.resolver else { return nil }
        return id
    }

    /// Puts `productID` at the head of the deck.
    ///
    /// The head of the deck and the card the person is being asked about are the same thing
    /// throughout the app — the swipe, ``MissionThread/nextCard``, and the App Intents' "the product
    /// I'm looking at" all resolve against it. Sequencing a kit by part is what makes them able to
    /// disagree, so every path that chooses a card or rebuilds the deck brings them back in step.
    /// Only the named card moves; everything behind it keeps the curator's order.
    public mutating func bringToFrontOfDeck(_ productID: Product.ID) {
        guard remainingDeckIDs.first != productID, remainingDeckIDs.contains(productID) else { return }
        remainingDeckIDs.removeAll { $0 == productID }
        remainingDeckIDs.insert(productID, at: 0)
    }

    /// Appends a semantic line. The surrounding AppModel transaction owns revision advancement.
    public mutating func appendEvent(
        kind: MissionThreadEventKind,
        text: String,
        createdAt: Date,
        productID: Product.ID? = nil,
        operationID: String? = nil,
        blocks: [MissionMessageBlock] = [],
        chosenOptionID: String? = nil
    ) {
        timeline.append(MissionThreadEvent(
            sequence: nextTimelineSequence,
            kind: kind,
            text: text,
            createdAt: createdAt,
            productID: productID,
            operationID: operationID,
            blocks: blocks,
            chosenOptionID: chosenOptionID
        ))
    }

    /// Marks one committed aggregate transaction. Call exactly once after its state/event changes.
    public mutating func advanceRevision(at date: Date) {
        revision += 1
        updatedAt = max(date, createdAt)
    }

    /// Makes a question current after its prompt event and subject have been committed locally.
    /// The caller persists the surrounding aggregate transaction before enabling its answers.
    @discardableResult
    public mutating func installInteraction(
        promptEventID: String,
        subjectRevision: Int,
        kind: MissionInteractionKind,
        question: String,
        options: [MissionInteractionOption],
        selectionMode: MissionSelectionMode = .singleChoice,
        allowsFreeText: Bool,
        resolver: MissionInteractionResolver,
        createdAt: Date,
        id: String = UUID().uuidString
    ) throws -> MissionPendingInteraction {
        let prior = pendingInteraction
        let priorGeneration = interactionGeneration
        interactionGeneration += 1
        let interaction = MissionPendingInteraction(
            id: id,
            promptEventID: promptEventID,
            interactionGeneration: interactionGeneration,
            subjectRevision: subjectRevision,
            kind: kind,
            question: question,
            options: options,
            selectionMode: selectionMode,
            allowsFreeText: allowsFreeText,
            resolver: resolver,
            createdAt: createdAt
        )
        pendingInteraction = interaction
        do { try validate(interaction: interaction) }
        catch {
            pendingInteraction = prior
            interactionGeneration = priorGeneration
            throw error
        }
        return interaction
    }

    /// Validates identity and allowed answer shape without applying a commerce mutation.
    public func validate(_ submission: MissionInteractionSubmission) throws -> MissionPendingInteraction {
        guard blockingRecovery == nil else { throw MissionInteractionSubmissionError.blockedByRecovery }
        guard !submission.idempotencyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionInteractionSubmissionError.blankIdempotencyID
        }
        guard !timeline.contains(where: { $0.operationID == submission.idempotencyID }),
              !decisions.contains(where: { $0.id == submission.idempotencyID }) else {
            throw MissionInteractionSubmissionError.reusedIdempotencyID(submission.idempotencyID)
        }
        guard submission.threadID == id else { throw MissionInteractionSubmissionError.wrongThread }
        guard let interaction = pendingInteraction else { throw MissionInteractionSubmissionError.noPendingInteraction }
        guard submission.interactionID == interaction.id else { throw MissionInteractionSubmissionError.staleInteraction }
        guard submission.interactionGeneration == interaction.interactionGeneration else {
            throw MissionInteractionSubmissionError.staleGeneration(
                expected: interaction.interactionGeneration, received: submission.interactionGeneration
            )
        }
        guard submission.subjectRevision == interaction.subjectRevision else {
            throw MissionInteractionSubmissionError.staleSubject(
                expected: interaction.subjectRevision, received: submission.subjectRevision
            )
        }
        switch submission.answer {
        case .option(let id):
            guard interaction.options.contains(where: { $0.id == id }) else {
                throw MissionInteractionSubmissionError.unknownOption(id)
            }
        case .freeText(let text):
            guard interaction.allowsFreeText else { throw MissionInteractionSubmissionError.freeTextNotAllowed }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MissionInteractionSubmissionError.blankFreeText
            }
        }
        return interaction
    }

    /// Ends the current question epoch after the validated answer and its deterministic command
    /// have committed to the in-memory aggregate. A repeated old submission is then stale.
    public mutating func resolveInteraction(_ submission: MissionInteractionSubmission) throws {
        _ = try validate(submission)
        settleActivityPrompt(of: pendingInteraction)
        pendingInteraction = nil
        interactionGeneration += 1
    }

    public mutating func supersedePendingInteraction() {
        guard pendingInteraction != nil else { return }
        settleActivityPrompt(of: pendingInteraction)
        pendingInteraction = nil
        interactionGeneration += 1
    }

    /// A working question's prompt turn carries a live activity receipt. Once that question ends,
    /// mark the turn superseded so the transcript renders the receipt as finished work instead of
    /// leaving a spinner running forever in scrollback. Prompt turns without an activity block
    /// (product, plan, kit questions) stay untouched — answered history keeps its full weight.
    private mutating func settleActivityPrompt(of interaction: MissionPendingInteraction?) {
        guard let interaction,
              let index = timeline.firstIndex(where: { $0.id == interaction.promptEventID }),
              timeline[index].blocks.contains(where: { if case .activity = $0 { return true } else { return false } })
        else { return }
        timeline[index].isSuperseded = true
    }

    /// Converts durable in-flight work into one stable, retryable state without reissuing it.
    /// Calling this repeatedly is idempotent.
    public mutating func recoverAfterInterruption(at date: Date) throws {
        guard let pending = pendingOperation else { return }
        let alreadyNarrated = timeline.contains {
            $0.kind == .interrupted && $0.operationID == pending.id
        }

        retry = pending.retry
        switch pending.retry.kind {
        case .planning:
            phase = .failed
        case .gathering, .curation:
            phase = candidates.isEmpty ? pending.retry.returnPhase : .deckReady
        case .refinement:
            // Refinement builds its new working set off-snapshot and commits only after curation.
            // Therefore the persisted candidates/deck are already the last successful refinement,
            // while `baseCandidates` remains the user's explicit Reset target (the original deal).
            // The pending turn was appended before the model ran; remove it from active context so
            // Retry reuses the request exactly once instead of interpreting a duplicated turn.
            if refinementTurns.last == pending.retry.input { refinementTurns.removeLast() }
            for index in timeline.indices where timeline[index].operationID == pending.id {
                if timeline[index].kind == .userMessage || timeline[index].kind == .refinementRequested {
                    timeline[index].isSuperseded = true
                }
            }
            phase = .deckReady
        case .chips:
            phase = pending.retry.returnPhase
        }
        pendingOperation = nil
        if !alreadyNarrated {
            appendEvent(
                kind: .interrupted,
                text: "That work was interrupted. You can try it again.",
                createdAt: date,
                operationID: pending.id
            )
            advanceRevision(at: date)
        }
        try validateAndNormalize()
    }

    /// Validates cross-field invariants and applies only lossless deterministic normalization.
    public mutating func validateAndNormalize() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionThreadValidationError.blankID
        }
        guard !originalGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionThreadValidationError.blankGoal
        }
        guard revision >= 0 else { throw MissionThreadValidationError.invalidRevision(revision) }
        guard interactionGeneration >= 0 else {
            throw MissionThreadValidationError.invalidInteractionGeneration(interactionGeneration)
        }
        if updatedAt < createdAt { updatedAt = createdAt }

        plan = try Self.unique(plan, id: \.id, conflicting: MissionThreadValidationError.conflictingPlanID)
        candidates = try Self.unique(candidates, id: \.id, conflicting: MissionThreadValidationError.conflictingProductID)
        baseCandidates = try Self.unique(baseCandidates, id: \.id, conflicting: MissionThreadValidationError.conflictingProductID)

        let candidateIDs = Set(candidates.map(\.id))
        var seenDeck = Set<String>()
        remainingDeckIDs = try remainingDeckIDs.filter { id in
            guard candidateIDs.contains(id) else { throw MissionThreadValidationError.unresolvedDeckProduct(id) }
            return seenDeck.insert(id).inserted
        }

        var seenKit = Set<String>()
        for item in kit {
            guard seenKit.insert(item.product.id).inserted else {
                throw MissionThreadValidationError.duplicateKitProduct(item.product.id)
            }
            guard item.product.variants.contains(where: { $0.id == item.variant.id }) else {
                throw MissionThreadValidationError.invalidKitVariant(
                    productID: item.product.id,
                    variantID: item.variant.id
                )
            }
        }
        let unavailable = Set(kit.map(\.product.id))
            .union(decisions.filter { $0.kind == .skipped }.map(\.productID))
        remainingDeckIDs.removeAll { unavailable.contains($0) }

        let knownProducts = candidateIDs
            .union(baseCandidates.map(\.id))
            .union(kit.map { $0.product.id })
        var decisionIDs = Set<String>()
        for decision in decisions {
            guard decisionIDs.insert(decision.id).inserted else {
                throw MissionThreadValidationError.duplicateDecisionID(decision.id)
            }
            guard knownProducts.contains(decision.productID) else {
                throw MissionThreadValidationError.unresolvedDecisionProduct(decision.productID)
            }
        }

        timeline.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.createdAt < $1.createdAt
        }
        var timelineIDs = Set<String>()
        var sequences = Set<Int>()
        for event in timeline {
            guard timelineIDs.insert(event.id).inserted else {
                throw MissionThreadValidationError.duplicateTimelineID(event.id)
            }
            guard sequences.insert(event.sequence).inserted else {
                throw MissionThreadValidationError.duplicateTimelineSequence(event.sequence)
            }
            try validate(blocks: event.blocks)
        }

        if let interaction = pendingInteraction {
            try validate(interaction: interaction)
        }
        if case .savePendingInteraction = blockingRecovery, pendingInteraction == nil {
            throw MissionThreadValidationError.invalidInteraction("pending-interaction recovery has no question")
        }

        switch phase {
        case .planning, .declined, .completed, .abandoned:
            break
        case .planReady:
            guard task != nil, !plan.isEmpty else {
                throw MissionThreadValidationError.invalidPhase(phase, reason: "task and plan are required")
            }
        case .gathering:
            guard let task, !task.searchQueries.isEmpty else {
                throw MissionThreadValidationError.invalidPhase(phase, reason: "a searchable task is required")
            }
        case .deckReady:
            guard task != nil else {
                throw MissionThreadValidationError.invalidPhase(phase, reason: "a task is required")
            }
        case .failed:
            guard retry != nil else {
                throw MissionThreadValidationError.invalidPhase(phase, reason: "a retry descriptor is required")
            }
        }
    }

    private func validate(blocks: [MissionMessageBlock]) throws {
        for block in blocks {
            switch block {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MissionThreadValidationError.invalidInteraction("message block text is blank")
                }
            case .plan(let snapshot):
                guard !snapshot.id.isEmpty, snapshot.revision >= 0, !snapshot.parts.isEmpty else {
                    throw MissionThreadValidationError.unresolvedInteractionSnapshot(snapshot.id)
                }
                _ = try Self.unique(snapshot.parts, id: \.id, conflicting: MissionThreadValidationError.conflictingPlanID)
            case .product(let snapshot):
                try validate(productSnapshot: snapshot)
            case .comparison(let snapshot):
                for product in snapshot.products { try validate(productSnapshot: product) }
                guard snapshot.isPresentable else {
                    throw MissionThreadValidationError.unresolvedInteractionSnapshot(snapshot.id)
                }
            case .kit(let snapshot):
                guard !snapshot.id.isEmpty, snapshot.revision >= 0,
                      Set(snapshot.items.map(\.productID)).count == snapshot.items.count else {
                    throw MissionThreadValidationError.unresolvedInteractionSnapshot(snapshot.id)
                }
            case .activity(let receipt):
                guard !receipt.id.isEmpty,
                      !receipt.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MissionThreadValidationError.unresolvedInteractionSnapshot(receipt.id)
                }
            case .autoKeep(let snapshot):
                // An empty receipt is the failure mode worth catching: it would render as "Kept 0
                // picks on my own", claiming a pass that did nothing.
                let rows = snapshot.kept + snapshot.heldBack
                guard !snapshot.id.isEmpty, !snapshot.kept.isEmpty,
                      Set(rows.map(\.productID)).count == rows.count,
                      rows.allSatisfy({ !$0.productID.isEmpty && $0.presentedPrice >= 0
                          && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      snapshot.heldBack.isEmpty == (snapshot.heldBackReason == nil) else {
                    throw MissionThreadValidationError.unresolvedInteractionSnapshot(snapshot.id)
                }
            }
        }
    }

    private func validate(productSnapshot: MissionProductSnapshot) throws {
        guard productSnapshot.isPresentable else {
            throw MissionThreadValidationError.unresolvedInteractionSnapshot(productSnapshot.productID)
        }
    }

    private func validate(interaction: MissionPendingInteraction) throws {
        guard !interaction.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionThreadValidationError.invalidInteraction("id is blank")
        }
        guard !interaction.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MissionThreadValidationError.invalidInteraction("question is blank")
        }
        guard interaction.interactionGeneration == interactionGeneration,
              interaction.interactionGeneration > 0 else {
            throw MissionThreadValidationError.invalidInteraction("generation does not match the active epoch")
        }
        guard interaction.subjectRevision >= 0, interaction.subjectRevision <= revision else {
            throw MissionThreadValidationError.invalidInteraction("subject revision is outside the thread history")
        }
        guard let prompt = timeline.first(where: { $0.id == interaction.promptEventID }) else {
            throw MissionThreadValidationError.unresolvedInteractionPrompt(interaction.promptEventID)
        }
        guard prompt.kind != .userMessage, !prompt.isSuperseded else {
            throw MissionThreadValidationError.invalidInteraction("prompt is not a current assistant turn")
        }
        guard interaction.options.count <= 4,
              interaction.allowsFreeText || !interaction.options.isEmpty else {
            throw MissionThreadValidationError.invalidInteraction("requires one to four choices or free text")
        }
        var optionIDs = Set<String>()
        for option in interaction.options {
            guard !option.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  optionIDs.insert(option.id).inserted else {
                throw MissionThreadValidationError.invalidInteraction("option IDs and labels must be nonblank and unique")
            }
        }

        switch interaction.resolver {
        case .clarification(let contextID):
            guard !contextID.isEmpty, interaction.kind == .clarification else {
                throw MissionThreadValidationError.invalidInteraction("clarification resolver does not match its kind")
            }
        case .plan(let planRevision):
            guard planRevision == interaction.subjectRevision,
                  !plan.isEmpty,
                  interaction.kind == .planApproval,
                  prompt.blocks.contains(where: { block in
                      if case .plan(let snapshot) = block {
                          return snapshot.revision == planRevision && snapshot.parts == plan
                              && snapshot.title == task?.title
                      }
                      return false
                  }) else {
                throw MissionThreadValidationError.invalidInteraction("plan resolver does not match a frozen plan")
            }
        case let .product(productID, variantID):
            guard interaction.kind == .productDecision || interaction.kind == .variantSelection else {
                throw MissionThreadValidationError.invalidInteraction("product resolver does not match its kind")
            }
            let products = candidates + baseCandidates + kit.map(\.product)
            guard let product = products.first(where: { $0.id == productID }) else {
                throw MissionThreadValidationError.unresolvedInteractionProduct(productID)
            }
            if let variantID, !product.variants.contains(where: { $0.id == variantID }) {
                throw MissionThreadValidationError.unresolvedInteractionVariant(productID: productID, variantID: variantID)
            }
            let variant = variantID.flatMap { id in product.variants.first { $0.id == id } }
            func matches(_ snapshot: MissionProductSnapshot) -> Bool {
                snapshot.productID == productID && snapshot.variantID == variantID
                    && snapshot.title == product.name && snapshot.merchant == product.shop.name
                    && snapshot.imageURL == product.imageURL
                    && snapshot.presentedPrice == (variant?.price ?? product.price)
                    && snapshot.variantTitle == variant?.title && snapshot.rationale == product.rationale
            }
            // The frozen snapshot an answer refers to may be presented on its own *or* as the
            // leading entry of a comparison — Crumb states one recommendation and shows the two
            // foils that make it legible. Either way the identity being written is the one that
            // was rendered, which is the property this check exists to hold.
            guard prompt.blocks.contains(where: { block in
                switch block {
                case .product(let snapshot): return matches(snapshot)
                case .comparison(let snapshot): return snapshot.products.contains(where: matches)
                default: return false
                }
            }) else {
                throw MissionThreadValidationError.unresolvedInteractionSnapshot(productID)
            }
        case .retry:
            guard interaction.kind == .retry || interaction.kind == .recovery else {
                throw MissionThreadValidationError.invalidInteraction("retry resolver does not match its kind")
            }
        case let .kit(snapshotID, snapshotRevision):
            guard interaction.kind == .cartReview,
                  snapshotRevision == interaction.subjectRevision,
                  timeline.contains(where: { event in event.blocks.contains { block in
                      if case .kit(let snapshot) = block {
                          return snapshot.id == snapshotID && snapshot.revision == snapshotRevision
                              && snapshot.items == kit.map(MissionKitSnapshotItem.init)
                      }
                      return false
                  } }) else {
                throw MissionThreadValidationError.unresolvedInteractionSnapshot(snapshotID)
            }
        case .refinement(let baseRevision):
            guard interaction.kind == .refinement, baseRevision == interaction.subjectRevision else {
                throw MissionThreadValidationError.invalidInteraction("refinement resolver does not match its subject")
            }
        }
    }

    private static func unique<Value: Hashable>(
        _ values: [Value],
        id: KeyPath<Value, String>,
        conflicting: (String) -> MissionThreadValidationError
    ) throws -> [Value] {
        var byID: [String: Value] = [:]
        var ordered: [Value] = []
        for value in values {
            let key = value[keyPath: id]
            if let prior = byID[key] {
                guard prior == value else { throw conflicting(key) }
                continue
            }
            byID[key] = value
            ordered.append(value)
        }
        return ordered
    }
}

/// Frozen version-1 persistence envelope. Future domain changes add a new document DTO and a
/// migration rather than teaching this shape new required fields.
public struct MissionThreadDocumentV1: Sendable, Codable {
    public static let version = 1
    public let schemaVersion: Int
    public let id: String
    public let revision: Int
    public let originalGoal: String
    public let goal: String
    public let phase: MissionThreadPhase
    public let task: ShoppingTask?
    public let plan: [MissionPlanPart]
    public let candidates: [Product]
    public let baseCandidates: [Product]
    public let remainingDeckIDs: [Product.ID]
    public let kit: [KitItem]
    public let decisions: [MissionProductDecision]
    public let refinementTurns: [String]
    public let refinementDirectives: [RefinementDirective]
    public let recipient: Recipient?
    public let tasteSnapshot: TasteProfile
    public let pendingOperation: MissionPendingOperation?
    public let retry: MissionRetryDescriptor?
    public let timeline: [MissionThreadEvent]
    public let historyEntryID: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(thread: MissionThread) {
        self.schemaVersion = Self.version
        id = thread.id
        revision = thread.revision
        originalGoal = thread.originalGoal
        goal = thread.goal
        phase = thread.phase
        task = thread.task
        plan = thread.plan
        candidates = thread.candidates
        baseCandidates = thread.baseCandidates
        remainingDeckIDs = thread.remainingDeckIDs
        kit = thread.kit
        decisions = thread.decisions
        refinementTurns = thread.refinementTurns
        refinementDirectives = thread.refinementDirectives
        recipient = thread.recipient
        tasteSnapshot = thread.tasteSnapshot
        pendingOperation = thread.pendingOperation
        retry = thread.retry
        timeline = thread.timeline
        historyEntryID = thread.historyEntryID
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
    }

    public var thread: MissionThread {
        MissionThread(
            id: id,
            revision: revision,
            originalGoal: originalGoal,
            goal: goal,
            phase: phase,
            task: task,
            plan: plan,
            candidates: candidates,
            baseCandidates: baseCandidates,
            remainingDeckIDs: remainingDeckIDs,
            kit: kit,
            decisions: decisions,
            refinementTurns: refinementTurns,
            refinementDirectives: refinementDirectives,
            recipient: recipient,
            tasteSnapshot: tasteSnapshot,
            pendingOperation: pendingOperation,
            retry: retry,
            timeline: timeline,
            historyEntryID: historyEntryID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// Version 2 adds the durable interaction epoch, typed resolver, blocking save recovery, and
/// frozen message blocks. Nesting the aggregate makes this document's shape independent from V1;
/// future migrations must continue to decode V1 through its frozen DTO above.
public struct MissionThreadDocumentV2: Sendable, Codable {
    public static let version = 2
    public let schemaVersion: Int
    public let thread: MissionThread

    public init(thread: MissionThread) {
        schemaVersion = Self.version
        self.thread = thread
    }
}

/// Version-dispatching JSON codec for the aggregate blob.
public enum MissionThreadCodec {
    public static let currentVersion = MissionThreadDocumentV2.version

    private struct Header: Decodable { let schemaVersion: Int }

    public static func schemaVersion(in data: Data) throws -> Int {
        try JSONDecoder().decode(Header.self, from: data).schemaVersion
    }

    public static func encode(_ thread: MissionThread) throws -> Data {
        var valid = thread
        try valid.validateAndNormalize()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(MissionThreadDocumentV2(thread: valid))
    }

    public static func decode(_ data: Data) throws -> MissionThread {
        let version = try schemaVersion(in: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var thread: MissionThread
        switch version {
        case MissionThreadDocumentV1.version:
            // V1 had no actionable question. Migration deliberately invents neither a resolver nor
            // a write-capable interaction; the application derives the next prompt explicitly.
            thread = try decoder.decode(MissionThreadDocumentV1.self, from: data).thread
        case MissionThreadDocumentV2.version:
            thread = try decoder.decode(MissionThreadDocumentV2.self, from: data).thread
        default:
            throw MissionThreadCodecError.unsupportedVersion(version)
        }
        try thread.validateAndNormalize()
        return thread
    }
}

public enum MissionThreadCodecError: Error, Hashable, Sendable {
    case unsupportedVersion(Int)
}
