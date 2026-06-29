import Testing
import Foundation
@testable import CrumbKit

/// The pure history-trim policy behind ``CrumbContext`` — the principled replacement for PR #12's
/// inline `maximumResponseTokens` band-aid. The `Transcript.Entry` adapter (`trimmed`) runs only on
/// the model path (untested, like every model call), but ``CrumbContext/keptIndices(count:isPinned:turns:)``
/// is exhaustively exercised here: it's what guarantees the on-device window stays bounded without
/// dropping the persona or the live tail.
@Suite("CrumbContext history trim")
struct CrumbContextTests {

    /// No entries → nothing kept.
    @Test("Empty transcript keeps nothing")
    func empty() {
        #expect(CrumbContext.keptIndices(count: 0, isPinned: { _ in false }) == [])
    }

    /// A transcript already within budget is kept whole, in order.
    @Test("Under budget keeps every entry in order")
    func underBudget() {
        let kept = CrumbContext.keptIndices(count: 5, isPinned: { _ in false }, turns: 8)
        #expect(kept == [0, 1, 2, 3, 4])
    }

    /// Over budget drops the older middle, keeping the pinned head + the most recent `turns`.
    @Test("Over budget drops the middle, keeps pinned head + recent tail")
    func overBudget() {
        // 10 entries, index 0 pinned (instructions), keep last 3 non-pinned.
        let kept = CrumbContext.keptIndices(count: 10, isPinned: { $0 == 0 }, turns: 3)
        #expect(kept == [0, 7, 8, 9])
    }

    /// Every pinned entry survives a trim, wherever it sits.
    @Test("All pinned entries are always kept")
    func pinnedAlwaysKept() {
        let kept = CrumbContext.keptIndices(count: 10, isPinned: { $0 == 0 || $0 == 1 }, turns: 2)
        #expect(kept == [0, 1, 8, 9])
    }

    /// A pinned entry in the middle is preserved and is not counted against the recent-turns budget.
    @Test("A mid-transcript pinned entry is preserved")
    func pinnedInMiddle() {
        let kept = CrumbContext.keptIndices(count: 6, isPinned: { $0 == 2 }, turns: 1)
        #expect(kept == [2, 5])
    }

    /// `turns == 0` keeps only the pinned entries (the persona), dropping all conversation.
    @Test("Zero turns keeps only pinned entries")
    func zeroTurns() {
        #expect(CrumbContext.keptIndices(count: 5, isPinned: { $0 == 0 }, turns: 0) == [0])
        #expect(CrumbContext.keptIndices(count: 5, isPinned: { _ in false }, turns: 0) == [])
    }

    /// The default budget is the documented constant — a regression guard so a silent change to the
    /// window policy is caught.
    @Test("Default history turns is the documented budget")
    func defaultBudget() {
        #expect(CrumbContext.defaultHistoryTurns == 8)
        #expect(CrumbContext.onDeviceContextTokens == 4096)
    }
}
