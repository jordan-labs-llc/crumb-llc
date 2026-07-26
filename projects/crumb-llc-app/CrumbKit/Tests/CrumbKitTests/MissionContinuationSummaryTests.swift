import Testing
import Foundation
@testable import CrumbKit

@Suite("MissionContinuationSummary")
struct MissionContinuationSummaryTests {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let taste = TasteProfile(
        vibe: ["calm"], leanings: ["durable"], budgetComfort: 0.4,
        signatureLine: "quietly useful"
    )

    private func thread(_ phase: MissionThreadPhase) -> MissionThread {
        var thread = MissionThread(goal: "Find premium jasmine tea", taste: Self.taste, now: Self.now)
        thread.phase = phase
        return thread
    }

    private func product(_ id: String, price: Decimal) -> Product {
        Product(
            id: id,
            name: "Tea \(id)",
            shop: SeedData.Shops.millOak,
            price: price,
            rating: 4.5,
            reviews: 12,
            rationale: "test fixture",
            symbol: "leaf",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id)-v", title: "Default", price: price)]
        )
    }

    @Test("A settled gather that found nothing says so instead of claiming picks are ready")
    func emptyDeckReadyDoesNotLie() {
        // The regression: `deckReady` means the gather finished, not that it found anything, so
        // deriving the label from phase alone rendered "Picks ready" over an empty deck.
        let settled = thread(.deckReady)
        #expect(settled.kit.isEmpty)
        #expect(settled.remainingDeckIDs.isEmpty)
        #expect(MissionContinuationSummary.text(for: settled) == "Nothing found yet")
    }

    @Test("Unreviewed picks are counted, and the count is not pluralized at one")
    func unreviewedPicksAreCounted() {
        var many = thread(.deckReady)
        many.candidates = (1...12).map { product("p\($0)", price: 20) }
        many.remainingDeckIDs = many.candidates.map(\.id)
        #expect(MissionContinuationSummary.text(for: many) == "12 picks to review")

        var one = thread(.deckReady)
        one.candidates = [product("p1", price: 20)]
        one.remainingDeckIDs = ["p1"]
        #expect(MissionContinuationSummary.text(for: one) == "1 pick to review")
    }

    @Test("Kept items outrank unreviewed ones and report the kit subtotal")
    func keptItemsWinAndCarryPrice() {
        var thread = thread(.deckReady)
        let a = product("a", price: 32)
        let b = product("b", price: 54)
        thread.candidates = [a, b]
        // Still one pick left to look at — the kit is what the person comes back for.
        thread.remainingDeckIDs = ["b"]
        thread.kit = [KitItem(product: a), KitItem(product: b)]
        #expect(MissionContinuationSummary.text(for: thread) == "2 kept · $86.00")

        var single = self.thread(.deckReady)
        single.candidates = [a]
        single.kit = [KitItem(product: a)]
        #expect(MissionContinuationSummary.text(for: single) == "1 kept · $32.00")
    }

    @Test("Phases with no contents to contradict keep their plain wording")
    func contentlessPhasesAreUnchanged() {
        let expected: [MissionThreadPhase: String] = [
            .planning: "Planning",
            .planReady: "Ready to shop",
            .gathering: "Searching shops",
            .failed: "Needs attention",
            .declined: "Ready for another goal",
            .completed: "Completed",
            .abandoned: "Ended",
        ]
        for (phase, text) in expected {
            #expect(MissionContinuationSummary.text(for: thread(phase)) == text)
        }
    }

    @Test("A still-searching thread never reports contents, even once candidates have landed")
    func gatheringIgnoresPartialContents() {
        // Mid-gather the deck is filling in; the row must not start announcing counts that are
        // about to change under the reader.
        var gathering = thread(.gathering)
        gathering.candidates = [product("a", price: 10)]
        gathering.remainingDeckIDs = ["a"]
        #expect(MissionContinuationSummary.text(for: gathering) == "Searching shops")
    }
}
