import Foundation

/// Deterministic, offline ``RefinementInterpreter`` — the default for the scaffold and the only
/// interpreter that runs on the simulator/CI (where the on-device model is unavailable).
///
/// It does not try to *understand* the refinement; it maps the quick chips to fixed directives
/// and runs a light keyword heuristic over free text. That's enough to make every demo path
/// render with no model: a price word re-sorts the deck, an "add X" lead pulls new items in, a
/// "no X" lead demotes them, and anything else becomes an `emphasis` note that the curator's
/// deterministic shaping (and on-device voice, when up) honors. It is also the shared home for
/// the pure ``cleanDirective(_:)`` reconcile both interpreters funnel through.
public struct RuleBasedRefinementInterpreter: RefinementInterpreter {

    public init() {}

    public func interpret(
        _ refinement: String,
        conversation: [String],
        mission: ShoppingTask,
        profile: TasteProfile
    ) async -> InterpretedRefinement {
        // `reason: nil` — a *chosen* default here (mock scaffold / sim), so the UI stays quiet.
        // When `AppleFoundationRefinementInterpreter` degrades to this floor it calls
        // `Self.interpret(text:reason:)` with a real reason so the honest note shows.
        Self.interpret(text: refinement, reason: nil)
    }

    /// The deterministic interpretation, with an explicit fallback `reason` so the AI interpreter
    /// can reuse this floor and still report *why* it degraded. Pure (no model, no I/O) — the
    /// unit-tested guarantee behind the seam.
    static func interpret(text: String, reason: RefinementTier.Fallback?) -> InterpretedRefinement {
        let directive = cleanDirective(heuristicDirective(for: text))
        return InterpretedRefinement(directive: directive, tier: .ruleBased(reason))
    }

    // MARK: - Quick-chip directives (shared by the bar and tests)

    /// The fixed quick-refinement chips shown on the Curate screen. Each maps to a deterministic
    /// directive so a tap behaves identically with or without a model. The chips double as the
    /// discoverable, headless-screenshot-able affordance for the free-text bar.
    public enum Chip: String, CaseIterable, Sendable {
        case cheaper
        case warmer
        case fewer
        case durable

        /// The user-facing chip label.
        public var label: String {
            switch self {
            case .cheaper: return "Cheaper"
            case .warmer: return "Warmer"
            case .fewer: return "Fewer"
            case .durable: return "More durable"
            }
        }

        /// The refinement sentence a tap submits — the same text a user could have typed, so the
        /// chip path and the free-text path run through one interpreter.
        public var refinementText: String {
            switch self {
            case .cheaper: return "make it cheaper"
            case .warmer: return "warmer tones and materials"
            case .fewer: return "fewer, only the essentials"
            case .durable: return "more durable, built to last"
            }
        }
    }

    // MARK: - Free-text heuristic (pure, exhaustively tested)

    /// Reads a refinement line into a raw directive with a small, deterministic ruleset. The order
    /// matters: a price ask is detected before a removal so "make it cheaper" never reads as
    /// "remove cheaper", and an "add" lead is detected before falling back to a plain emphasis.
    static func heuristicDirective(for text: String) -> RefinementDirective {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RefinementDirective() }
        let lowered = trimmed.lowercased()

        let price = priceDirection(in: lowered)
        if let add = addQuery(in: trimmed, lowered: lowered) {
            // "add rain pants" — pull new candidates in. Carry any price lean too.
            return RefinementDirective(addQueries: [add], priceDirection: price)
        }
        if let remove = removeHint(in: trimmed, lowered: lowered) {
            return RefinementDirective(priceDirection: price, removeHints: [remove])
        }
        if price != .none {
            // A pure price ask ("make it cheaper") — no emphasis needed; the sort is the change.
            return RefinementDirective(priceDirection: price)
        }
        // Anything else is an emphasis note: re-rank/re-voice toward the user's words.
        return RefinementDirective(emphasis: trimmed)
    }

    private static func priceDirection(in lowered: String) -> RefinementDirective.PriceDirection {
        if cheaperWords.contains(where: lowered.contains) { return .cheaper }
        if pricierWords.contains(where: lowered.contains) { return .pricier }
        return .none
    }

    /// Captures the noun phrase after an "add"-style lead as a catalog query, e.g.
    /// "add rain pants" → "rain pants", "also need a kettle" → "a kettle". Returns `nil` when no
    /// add-lead is present. Reuses ``RuleBasedMissionPlanner/clean(query:)`` for spacing.
    private static func addQuery(in text: String, lowered: String) -> String? {
        for lead in addLeads where lowered.hasPrefix(lead + " ") || lowered.contains(" " + lead + " ") {
            let remainder = phrase(after: lead, in: text)
            let cleaned = RuleBasedMissionPlanner.clean(query: remainder)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// Captures the noun phrase after a "remove"-style lead as a demote hint, e.g.
    /// "no synthetic" → "synthetic". Returns `nil` when no remove-lead is present.
    private static func removeHint(in text: String, lowered: String) -> String? {
        for lead in removeLeads where lowered.hasPrefix(lead + " ") || lowered.contains(" " + lead + " ") {
            let remainder = phrase(after: lead, in: text)
            let cleaned = RuleBasedMissionPlanner.clean(query: remainder)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// The text following the first occurrence of `lead` (word-boundaried), original case kept.
    private static func phrase(after lead: String, in text: String) -> String {
        let lowered = text.lowercased()
        // Find the lead as a leading word or an interior word.
        let candidates = [lead + " "].flatMap { needle -> [Range<String.Index>] in
            var ranges: [Range<String.Index>] = []
            if lowered.hasPrefix(needle), let r = lowered.range(of: needle) { ranges.append(r) }
            if let r = lowered.range(of: " " + needle) {
                // Shift past the leading space to start at the lead word.
                let start = lowered.index(after: r.lowerBound)
                ranges.append(start..<r.upperBound)
            }
            return ranges
        }
        guard let first = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else { return "" }
        return String(text[first.upperBound...])
    }

    private static let cheaperWords = [
        "cheap", "cheaper", "afford", "budget", "less expensive", "lower price", "save money",
    ]
    private static let pricierWords = [
        "splurge", "premium", "pricier", "higher-end", "high end", "invest", "best quality",
        "nicer", "luxury",
    ]
    // Strong verbs first so a discourse marker ("also"/"with") never wins over the real ask in
    // "I also need a headlamp" — the first lead matched is the one we strip up to.
    private static let addLeads = ["add", "include", "throw in", "need", "want", "also", "with"]
    private static let removeLeads = ["no", "without", "remove", "drop", "skip", "lose", "less"]

    // MARK: - Shared reconcile (the pure guarantee behind both interpreters)

    /// Cleans a raw directive into one safe to act on: trims the emphasis; trims/dedupes/caps
    /// `addQueries` (case-insensitive, first spelling wins, capped at
    /// ``RefinementDirective/maxAddQueries``); trims/dedupes `removeHints`. Pure — same input
    /// always yields the same directive.
    static func cleanDirective(_ raw: RefinementDirective) -> RefinementDirective {
        RefinementDirective(
            emphasis: raw.emphasis.trimmingCharacters(in: .whitespacesAndNewlines),
            addQueries: tidy(raw.addQueries, cap: RefinementDirective.maxAddQueries),
            priceDirection: raw.priceDirection,
            removeHints: tidy(raw.removeHints, cap: .max)
        )
    }

    /// Trims, drops blanks, dedupes case-insensitively (first spelling wins), and caps a list.
    private static func tidy(_ items: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            out.append(value)
            if out.count == cap { break }
        }
        return out
    }
}
