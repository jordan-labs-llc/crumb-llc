import Foundation

/// Deterministic, offline ``MissionPlanner`` — the default for the scaffold and the only
/// planner that runs on the simulator/CI (where the on-device model is unavailable).
///
/// It does **not** try to be clever: a shoppable goal becomes a one-part mission whose single
/// search query is the cleaned goal string. The live ``MockUCPClient`` keyword-matches that
/// query back to a seed deck, and the live broker runs it as a real catalog search — so even
/// the floor returns something honest. The richer multi-part decomposition is the job of
/// ``AppleFoundationMissionPlanner`` when a model tier is up; this is the dependable fallback
/// it degrades to (and the shared home for the pure helpers both planners use).
public struct RuleBasedMissionPlanner: MissionPlanner {

    public init() {}

    public func plan(goal: String, profile: TasteProfile) async -> PlannedMission {
        // `reason: nil` — this is a *chosen* default here (mock scaffold / sim), so the UI
        // stays quiet. When `AppleFoundationMissionPlanner` degrades to this floor it calls
        // `Self.plan(goal:reason:)` with a real reason so the honest note shows.
        Self.plan(goal: goal, reason: nil)
    }

    /// The deterministic plan, with an explicit fallback `reason` so the AI planner can reuse
    /// this floor and still report *why* it degraded. Pure (no model, no I/O) — the unit-tested
    /// guarantee behind the planning seam.
    static func plan(goal: String, reason: PlannerTier.Fallback?) -> PlannedMission {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShoppable(trimmed) else {
            return PlannedMission(task: nil, tier: .ruleBased(reason), decline: declineMessage)
        }
        let title = self.title(from: trimmed)
        let task = makeTask(
            goal: trimmed,
            title: title,
            subtitle: defaultSubtitle,
            note: curatorNote(forParts: [title]),
            parts: [(label: title, query: clean(query: trimmed))]
        )
        return PlannedMission(task: task, tier: .ruleBased(reason), decline: nil)
    }

    // MARK: - Shared pure helpers (used by AppleFoundationMissionPlanner too)

    /// How many parts a mission may carry. A guard rail so a runaway generation can't flood the
    /// plan list; parts past the cap are dropped in ``AppleFoundationMissionPlanner/mission(from:goal:tier:)``.
    /// Public so the in-app plan editor caps "add a part" the same way.
    public static let maxParts = 6

    /// A light, deterministic shoppability gate for the no-model path: reject the empty / far
    /// too short, and the obvious question ("what's the weather?"). The model path uses its own
    /// `isShoppable` judgment; this is the floor that still has to answer nonsense gracefully.
    static func isShoppable(_ goal: String) -> Bool {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let lowered = trimmed.lowercased()
        // A question with no shopping verb reads as "asking", not "shopping for".
        let asksAQuestion = trimmed.hasSuffix("?")
            && questionLeads.contains { lowered.hasPrefix($0) }
        return !asksAQuestion
    }

    private static let questionLeads = [
        "what", "who", "when", "where", "why", "how", "is ", "are ", "do ", "does ", "can ",
    ]

    /// Trims a query and collapses interior whitespace so the broker/mock see a clean keyword
    /// string. Punctuation is left to the caller's source text — we only normalize spacing.
    /// Public so the in-app plan editor re-derives a part's query from a reworded label.
    public static func clean(query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Title-cases the goal into a mission title, capping length so a paragraph-long goal can't
    /// blow out the header. First letter up, the rest left as the user wrote it.
    static func title(from goal: String) -> String {
        let cleaned = clean(query: goal)
        let capped = cleaned.count > 60 ? String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : cleaned
        guard let first = capped.first else { return capped }
        return first.uppercased() + capped.dropFirst()
    }

    /// A stable id derived from the goal text, so the same goal always yields the same id
    /// (App Intents / recents can re-resolve it without a stored table). Deterministic — no
    /// timestamps or randomness.
    static func missionID(for goal: String) -> String {
        let slug = clean(query: goal)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { acc, ch in
                if ch == "-" && acc.hasSuffix("-") { return }
                acc.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let trimmedSlug = String(slug.prefix(48))
        return "goal." + (trimmedSlug.isEmpty ? "mission" : trimmedSlug)
    }

    /// Picks a mission accent from the seed palette deterministically from the goal text, so
    /// the same goal always tints the same way (and we never ask the model for a color).
    static func accentHex(for goal: String) -> UInt32 {
        // A stable, order-independent hash over the scalars (Swift's `hashValue` is salted per
        // run, which would make the accent wobble between launches).
        let sum = clean(query: goal).lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let palette: [UInt32] = [0x1C4B43, 0xCC8A3A, 0x3F5A54, 0x7A5A3A]
        return palette[sum % palette.count]
    }

    /// A short, deterministic curator note for the plan screen when no model wrote one. Honest
    /// and quiet — it frames the plan without inventing specifics about the goal.
    static func curatorNote(forParts parts: [String]) -> String {
        if parts.count <= 1 {
            return "Here's where I'd start. Tweak the plan if you want, then I'll go find the "
                + "pieces across the shops."
        }
        return "Here's how I'd break this down — \(parts.count) parts. Reword or trim anything, "
            + "then I'll go find the pieces across the shops."
    }

    /// The friendly answer when a goal isn't something Crumb can shop for.
    static let declineMessage =
        "I'm a shopping curator — hand me something to shop for, like \u{201C}set up my "
        + "pour-over corner\u{201D} or \u{201C}pack me for a rainy hike.\u{201D}"

    /// The neutral subtitle used when there's no model to write a richer one.
    static let defaultSubtitle = "A mission for you"

    /// Assembles a ``ShoppingTask`` from validated parts. The single shared constructor both
    /// planners funnel through, so id / accent / plan / queries are derived one way.
    static func makeTask(
        goal: String,
        title: String,
        subtitle: String,
        note: String,
        parts: [(label: String, query: String)]
    ) -> ShoppingTask {
        ShoppingTask(
            id: missionID(for: goal),
            title: title,
            subtitle: subtitle,
            plan: parts.map(\.label),
            curatorNote: note,
            accentHex: accentHex(for: goal),
            candidateIDs: [],
            searchQueries: parts.map(\.query)
        )
    }
}
