import Foundation
import FoundationModels

/// Principled context-window management for Crumb's on-device Foundation Models sessions.
///
/// The on-device `SystemLanguageModel` has a hard **4096-token** context window — the transcript
/// (instructions + every prompt/response/tool turn) plus the next generation must fit inside it.
/// PR #12 fenced the one overflow we hit with an inline `GenerationOptions(maximumResponseTokens:)`
/// band-aid at the call site (see [[planner-context-overflow-and-relevance-gate]]). The dynamic-session
/// API lets us state the policy *declaratively* instead:
///
/// - the **response** bound moves onto each seam's `Profile` via `.maximumResponseTokens(_:)`
///   (a named policy, not a magic number passed to `respond`);
/// - the **history** bound is a `Profile.historyTransform { … }` that trims the transcript before
///   each turn — the real lever once a session accumulates turns (the agentic Tool loop);
/// - `.transcriptErrorHandlingPolicy(.revertTranscript)` keeps a session usable if a turn still
///   trips `GenerationError.exceededContextWindowSize`, rather than corrupting the transcript.
///
/// ``keptIndices(count:isPinned:turns:)`` is the pure, unit-tested core of the history trim:
/// single-shot seams (curator rank/voice, planner, …) never grow a transcript so it's a no-op for
/// them today, but it is the same policy the agentic driver leans on in the Tool loop, so it lives
/// here once and is exercised by tests rather than only by the model path.
public enum CrumbContext {

    /// The on-device model's context window, in tokens. The hard ceiling every on-device session
    /// shares; the trim/response policies keep the transcript comfortably under it.
    public static let onDeviceContextTokens = 4096

    /// How many of the most recent *non-pinned* transcript entries (prompt/response/tool turns) to
    /// retain by default. Instructions are always pinned and never counted against this.
    public static let defaultHistoryTurns = 8

    /// Pure history-trim policy: the indices to **keep** from a transcript of `count` entries —
    /// every *pinned* entry (the session instructions) plus the most recent `turns` non-pinned
    /// entries, in original order. Dropping the older middle keeps the window bounded while
    /// preserving the persona (instructions) and the live tail of the conversation.
    ///
    /// Pure and model-free: depends only on `count`, the `isPinned` predicate, and `turns`. This is
    /// the unit-tested guarantee behind ``trimmed(_:turns:)``.
    public static func keptIndices(
        count: Int,
        isPinned: (Int) -> Bool,
        turns: Int = defaultHistoryTurns
    ) -> [Int] {
        guard count > 0 else { return [] }
        var kept = Set<Int>()
        // Always keep the pinned (instructions) entries.
        for index in 0..<count where isPinned(index) { kept.insert(index) }
        // Keep the most recent `turns` non-pinned entries, scanning from the end.
        var keptRecent = 0
        var index = count - 1
        while index >= 0 && keptRecent < max(0, turns) {
            if !isPinned(index) {
                kept.insert(index)
                keptRecent += 1
            }
            index -= 1
        }
        return kept.sorted()
    }

    /// Adapts ``keptIndices(count:isPinned:turns:)`` to a real `Transcript.Entry` list, pinning the
    /// `.instructions` entry so the persona always survives a trim. Used as a `Profile`'s
    /// `historyTransform`.
    public static func trimmed(
        _ entries: [Transcript.Entry],
        turns: Int = defaultHistoryTurns
    ) -> [Transcript.Entry] {
        let kept = keptIndices(
            count: entries.count,
            isPinned: { index in
                if case .instructions = entries[index] { return true }
                return false
            },
            turns: turns
        )
        return kept.map { entries[$0] }
    }
}
