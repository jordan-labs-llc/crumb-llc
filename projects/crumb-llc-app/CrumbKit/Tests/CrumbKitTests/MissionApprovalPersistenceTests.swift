import Testing
import Foundation
@testable import CrumbKit

/// Delegation added three durable things to the aggregate — an approval mode, a decision's author,
/// and the receipt for an unwatched pass. Each has to survive a round trip, and — the part that
/// actually breaks apps — each has to be *absent-safe*, because every thread already on disk was
/// written before any of them existed. A required field here would quarantine a real person's
/// in-flight mission.
@Suite("Mission approvals persistence")
struct MissionApprovalPersistenceTests {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let taste = TasteProfile(
        vibe: ["calm"], leanings: ["durable"], budgetComfort: 0.4, signatureLine: "quietly useful"
    )

    private func deckThread() -> MissionThread {
        var thread = MissionThread(goal: "Pack me for a rainy hike", taste: Self.taste, now: Self.now)
        thread.task = SeedData.hike
        thread.plan = zip(SeedData.hike.plan, SeedData.hike.searchQueries).enumerated().map {
            MissionPlanPart(id: "part-\($0.offset)", label: $0.element.0, query: $0.element.1)
        }
        thread.candidates = Array(SeedData.hikeProducts.prefix(3))
        thread.baseCandidates = thread.candidates
        thread.remainingDeckIDs = thread.candidates.map(\.id)
        thread.phase = .deckReady
        thread.advanceRevision(at: Self.now.addingTimeInterval(1))
        return thread
    }

    private func row(_ id: String) -> MissionAutoKeepRow {
        MissionAutoKeepRow(
            productID: id, title: "Rain Shell", merchant: "Mill & Oak",
            presentedPrice: 120, part: "Waterproof jacket"
        )
    }

    @Test("Mode, author, receipt and undo all survive the V2 round trip")
    func roundTrip() throws {
        var thread = deckThread()
        let product = thread.candidates[0]
        thread.approvalMode = .auto
        thread.kit = [KitItem(product: product, variant: product.defaultVariant)]
        thread.remainingDeckIDs.removeAll { $0 == product.id }
        thread.decisions = [MissionProductDecision(
            id: "auto-1", kind: .added, productID: product.id,
            variantID: product.defaultVariant.id, createdAt: Self.now, decidedBy: .crumb
        )]
        thread.appendEvent(
            kind: .assistantMessage, text: "", createdAt: Self.now,
            blocks: [.autoKeep(MissionAutoKeepSnapshot(id: "auto-1", kept: [row(product.id)]))]
        )
        thread.pendingAutoKeepUndo = MissionAutoKeepUndo(
            receiptIDs: ["auto-1"], decisionIDs: ["auto-1"], productIDs: [product.id]
        )

        let decoded = try MissionThreadCodec.decode(MissionThreadCodec.encode(thread))
        #expect(decoded.approvalMode == .auto)
        #expect(decoded.decisions.first?.decidedBy == .crumb)
        #expect(decoded.decisions.first?.wasDecidedByCrumb == true)
        #expect(decoded.pendingAutoKeepUndo?.productIDs == [product.id])
        guard case .autoKeep(let snapshot)? = decoded.timeline.last?.blocks.first else {
            Issue.record("the receipt block did not survive"); return
        }
        #expect(snapshot.kept.map(\.productID) == [product.id])
        #expect(snapshot.kept.first?.part == "Waterproof jacket")
    }

    @Test("A thread written before delegation existed decodes as asking about each pick")
    func absentFieldsDecodeAsTheOldBehavior() throws {
        // Encoded from a thread that never set any of the new fields — the shape of every document
        // already on disk.
        var legacy = deckThread()
        legacy.decisions = [MissionProductDecision(
            id: "d1", kind: .added, productID: legacy.candidates[0].id,
            variantID: legacy.candidates[0].defaultVariant.id, createdAt: Self.now
        )]
        let decoded = try MissionThreadCodec.decode(MissionThreadCodec.encode(legacy))
        #expect(decoded.approvalMode == nil)
        #expect(decoded.pendingAutoKeepUndo == nil)
        // `nil` must read as the person, never as Crumb: every one of those decisions was a tap.
        #expect(decoded.decisions.first?.decidedBy == nil)
        #expect(decoded.decisions.first?.wasDecidedByCrumb == false)
    }

    @Test("A second pass folds into the outstanding reversal instead of replacing it")
    func undoMergesPasses() {
        // A refinement can settle straight into a second pass. One chip reading "Undo those 2" that
        // silently leaves three earlier picks in the kit is worse than no chip at all.
        let first = MissionAutoKeepUndo(receiptIDs: ["r1"], decisionIDs: ["d1", "d2"], productIDs: ["p1", "p2"])
        let second = MissionAutoKeepUndo(receiptIDs: ["r2"], decisionIDs: ["d2", "d3"], productIDs: ["p2", "p3"])
        let merged = first.merging(second)
        #expect(merged.receiptIDs == ["r1", "r2"])
        #expect(merged.decisionIDs == ["d1", "d2", "d3"])   // no double-counting
        #expect(merged.productIDs == ["p1", "p2", "p3"])
    }

    @Test("A receipt claiming a pass that kept nothing is corrupt, not merely odd")
    func emptyReceiptIsRejected() {
        var thread = deckThread()
        thread.appendEvent(
            kind: .assistantMessage, text: "", createdAt: Self.now,
            blocks: [.autoKeep(MissionAutoKeepSnapshot(id: "auto-empty", kept: []))]
        )
        #expect(throws: (any Error).self) { try MissionThreadCodec.encode(thread) }
    }

    @Test("A held-back pick without its reason — or a reason without a pick — never reaches disk")
    func heldBackAndReasonTravelTogether() {
        var orphanRow = deckThread()
        orphanRow.appendEvent(
            kind: .assistantMessage, text: "", createdAt: Self.now,
            blocks: [.autoKeep(MissionAutoKeepSnapshot(
                id: "auto-2", kept: [row("a")], heldBack: [row("b")], heldBackReason: nil
            ))]
        )
        #expect(throws: (any Error).self) { try MissionThreadCodec.encode(orphanRow) }

        var orphanReason = deckThread()
        orphanReason.appendEvent(
            kind: .assistantMessage, text: "", createdAt: Self.now,
            blocks: [.autoKeep(MissionAutoKeepSnapshot(
                id: "auto-3", kept: [row("a")], heldBack: [], heldBackReason: "too pricey"
            ))]
        )
        #expect(throws: (any Error).self) { try MissionThreadCodec.encode(orphanReason) }
    }

    @Test("The same product cannot appear as both kept and handed back")
    func rowsAreUnique() {
        var thread = deckThread()
        thread.appendEvent(
            kind: .assistantMessage, text: "", createdAt: Self.now,
            blocks: [.autoKeep(MissionAutoKeepSnapshot(
                id: "auto-4", kept: [row("a")], heldBack: [row("a")], heldBackReason: "too pricey"
            ))]
        )
        #expect(throws: (any Error).self) { try MissionThreadCodec.encode(thread) }
    }
}
