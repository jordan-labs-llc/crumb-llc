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
/// ``trimmed(_:recentToolTurns:)`` is the history trim. Single-shot seams (curator rank/voice,
/// planner, …) never grow a transcript so it's a no-op for them, but the agentic Tool loop
/// accumulates a `toolCalls`/`toolOutput` turn per search — and a **naive** most-recent-N trim can
/// split a `toolCalls` from its `toolOutput`, producing a transcript the model cannot tokenize
/// ("Unable to tokenize prompt", learned at runtime on the sim). So the trim cuts only at
/// `toolCalls` *turn boundaries*: it keeps the setup (instructions + prompt) plus the most recent
/// whole tool turns, never orphaning a tool output. ``keptIndices(kinds:recentToolTurns:)`` is the
/// pure, unit-tested core.
public enum CrumbContext {

    /// The **fallback** on-device context window, in tokens, used only when the live model's real
    /// `contextSize` can't be read. The actual window is now queried per session and the response /
    /// deck caps are derived from it via ``TokenBudget`` (#37) — 8192 on newer hardware, 4096 on
    /// older. This constant is that documented floor, not an assumed ceiling.
    public static let onDeviceContextTokens = TokenBudget.fallbackContextWindow

    /// How many of the most recent *non-pinned* transcript entries to retain by default, for the
    /// generic (non-tool) trim. Instructions are always pinned and never counted against this.
    public static let defaultHistoryTurns = 8

    /// How many of the most recent whole **tool turns** the agentic loop keeps. A tool turn is a
    /// `toolCalls` entry and its `toolOutput`(s); cutting at turn boundaries never splits a pair.
    public static let defaultToolTurns = 4

    /// The kinds of transcript entry that matter to the trim. A test-friendly projection of
    /// `Transcript.Entry` so the trim policy is unit-tested without constructing real entries.
    public enum EntryKind: Sendable, Equatable {
        case instructions, prompt, toolCalls, toolOutput, response, reasoning, other
    }

    // MARK: Generic trim (single-shot / non-tool)

    /// Pure history-trim policy for a transcript with no tool turns: the indices to **keep** — every
    /// *pinned* entry (the session instructions) plus the most recent `turns` non-pinned entries, in
    /// original order. Pure and model-free.
    public static func keptIndices(
        count: Int,
        isPinned: (Int) -> Bool,
        turns: Int = defaultHistoryTurns
    ) -> [Int] {
        guard count > 0 else { return [] }
        var kept = Set<Int>()
        for index in 0..<count where isPinned(index) { kept.insert(index) }
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

    // MARK: Tool-loop trim (pair-safe)

    /// Pure, pair-safe history-trim policy for the agentic tool loop. Keeps the **setup** — every
    /// entry before the first `toolCalls` (instructions + prompt + any pre-tool reasoning) — plus the
    /// most recent `recentToolTurns` whole tool turns, by cutting at `toolCalls` boundaries so a
    /// `toolCalls`/`toolOutput` pair is never split. Returns all indices when there are `recentToolTurns`
    /// or fewer tool turns (nothing to trim) or no tool turns at all (a single-shot transcript).
    ///
    /// Pure and model-free — the unit-tested guarantee behind ``trimmed(_:recentToolTurns:)``.
    public static func keptIndices(
        kinds: [EntryKind],
        recentToolTurns: Int = defaultToolTurns
    ) -> [Int] {
        let count = kinds.count
        guard count > 0 else { return [] }
        let toolCallStarts = (0..<count).filter { kinds[$0] == .toolCalls }
        // No tool turns (single-shot), or few enough to keep whole → keep everything.
        guard let firstTool = toolCallStarts.first, toolCallStarts.count > max(0, recentToolTurns) else {
            return Array(0..<count)
        }
        // Cut at the start of the Nth-most-recent tool turn; keep the setup + everything from there.
        let cut = toolCallStarts[toolCallStarts.count - max(0, recentToolTurns)]
        let setup = Array(0..<firstTool)      // instructions + prompt + pre-tool entries
        let recent = Array(cut..<count)       // whole recent tool turns (starts on a toolCalls)
        return setup + recent
    }

    /// Maps a `Transcript.Entry` to its ``EntryKind``.
    public static func kind(of entry: Transcript.Entry) -> EntryKind {
        switch entry {
        case .instructions: return .instructions
        case .prompt: return .prompt
        case .toolCalls: return .toolCalls
        case .toolOutput: return .toolOutput
        case .response: return .response
        case .reasoning: return .reasoning
        @unknown default: return .other
        }
    }

    /// Adapts the pair-safe policy to a real `Transcript.Entry` list, for use as a `Profile`'s
    /// `historyTransform`. A no-op for single-shot transcripts; trims the agentic tool loop at whole
    /// turn boundaries.
    public static func trimmed(
        _ entries: [Transcript.Entry],
        recentToolTurns: Int = defaultToolTurns
    ) -> [Transcript.Entry] {
        let kept = keptIndices(kinds: entries.map(kind(of:)), recentToolTurns: recentToolTurns)
        return kept.map { entries[$0] }
    }
}
