import Foundation
import FoundationModels
import os

/// The "real" mission planner, built on Apple's Foundation Models — the agent that actually
/// *decomposes* a free-text goal. It mirrors ``AppleFoundationCurator`` / ``AppleFoundationTasteExtractor``
/// exactly: ``RuleBasedMissionPlanner`` stays the offline floor, and one guided `@Generable`
/// call turns "set up my pour-over corner" into a titled, multi-part, searchable mission.
///
/// ## Tiers & degrade order (same story as the curator)
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — gated behind
///    `CRUMB_PCC_ENABLED` because *constructing or querying* that type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process (an
///    uncatchable fatal error, not a throw). See the identical gate in ``AppleFoundationCurator``.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, no entitlement, the working
///    primary today.
/// 3. **Rule-based** — ``RuleBasedMissionPlanner``'s single-query plan, used when neither model
///    is usable. It reports *why* it degraded so the plan screen can show an honest note.
///
/// ## The planning call is the tier probe
/// Like the curator's ranking call, the single guided plan generation proves the tier: if it
/// throws (offline / system not ready) the planner degrades to the next tier / the rule-based
/// floor. The model's draft is then folded back into a searchable mission by the pure,
/// unit-tested ``mission(from:goal:tier:)`` — which drops blank/duplicate parts, caps the
/// count, backfills empty fields, and (for a shoppable goal the model returned nothing usable
/// for) falls back to the same single-query plan as the rule-based floor.
public struct AppleFoundationMissionPlanner: MissionPlanner {

    /// The deterministic floor: the degrade target and the source of the shared pure helpers.
    private let rule = RuleBasedMissionPlanner()

    /// Logs a *real* generation failure instead of swallowing it behind `try?` — the bug that
    /// made the planner silently fall back to the single-query floor on the Mac. Inspect with
    /// `log stream --predicate 'subsystem == "llc.crumb.CrumbKit"'`.
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "MissionPlanner")

    public init() {}

    public func plan(goal: String, profile: TasteProfile) async -> PlannedMission {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty goal never reaches the model — there's nothing to decompose.
        guard !trimmed.isEmpty else {
            return RuleBasedMissionPlanner.plan(goal: trimmed, reason: nil)
        }

        // Tier 1 — Private Cloud Compute (OS 27+), gated for the same entitlement-trap reason
        // as the curator. `try?` cannot rescue the trap, so the only safe gate is "don't
        // reference the type unless provisioned."
        #if CRUMB_PCC_ENABLED
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
                let session: MakeSession = { LanguageModelSession(model: pcc, instructions: $0) }
                if let planned = await attemptDecompose(trimmed, profile, session: session, tier: .privateCloud) {
                    return planned
                }
                // Planning probe failed (offline / transient) — fall through to on-device.
            }
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            let session: MakeSession = { LanguageModelSession(model: device, instructions: $0) }
            if let planned = await attemptDecompose(trimmed, profile, session: session, tier: .onDevice) {
                return planned
            }
            return RuleBasedMissionPlanner.plan(goal: trimmed, reason: .offlineOrError)
        case let .unavailable(reason):
            return RuleBasedMissionPlanner.plan(goal: trimmed, reason: Self.map(reason))
        }
    }

    // MARK: Decompose

    private typealias MakeSession = @Sendable (_ instructions: String) -> LanguageModelSession

    /// The on-device model's context window is 4096 tokens; the transcript is *instructions +
    /// prompt + the model's generated plan*. Left unbounded, an occasional runaway generation
    /// pushes the transcript past 4096 and `respond(generating:)` throws
    /// `LanguageModelError` ("…exceeds the maximum allowed context size of 4096") — the very
    /// error `try?` used to swallow into a single-query fallback. A normal ``MissionDraft`` plan
    /// is well under this cap, so bounding the response can't truncate a real plan; it only
    /// fences off the runaway. The fixed prompt cost is kept small by ``cappedGoal(_:)``.
    static let maxResponseTokens = 1024
    static let generationOptions = GenerationOptions(maximumResponseTokens: maxResponseTokens)

    /// Runs the planning probe with a single retry, **logging** (not silently swallowing) a
    /// thrown error. With default sampling a second generation is usually shorter, so a transient
    /// near-the-limit overflow recovers rather than degrading the user to the single-query floor.
    /// Returns `nil` only when both attempts throw — the caller then cascades / degrades.
    private func attemptDecompose(
        _ goal: String,
        _ profile: TasteProfile,
        session makeSession: @escaping MakeSession,
        tier: PlannerTier
    ) async -> PlannedMission? {
        do {
            return try await decompose(goal, profile, session: makeSession, tier: tier)
        } catch {
            Self.log.error("Planner generation threw (attempt 1, retrying): \(error.localizedDescription, privacy: .public)")
            do {
                return try await decompose(goal, profile, session: makeSession, tier: tier)
            } catch {
                Self.log.error("Planner generation threw (attempt 2, degrading to rule-based): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// One guided generation reads the goal into a ``MissionDraft``, which the pure
    /// ``mission(from:goal:tier:)`` folds into a searchable mission. Throws when the call fails,
    /// so the tier cascade / rule-based fallback in ``plan(goal:profile:)`` takes over. The
    /// response is bounded (see ``generationOptions``) so a runaway generation can't overflow the
    /// context window.
    private func decompose(
        _ goal: String,
        _ profile: TasteProfile,
        session makeSession: @escaping MakeSession,
        tier: PlannerTier
    ) async throws -> PlannedMission {
        let session = makeSession(Self.instructions(profile: profile))
        let response = try await session.respond(
            to: Self.prompt(for: goal),
            generating: MissionDraft.self,
            options: Self.generationOptions
        )
        return Self.mission(from: response.content, goal: goal, tier: tier)
    }

    // MARK: Reconcile (pure — the unit-tested guarantee behind the model call)

    /// Folds the model's ``MissionDraft`` into a ``PlannedMission`` that is always either a
    /// clean, searchable task or an honest decline — never a half-formed plan:
    ///
    /// - **Not shoppable** → `task == nil` with a trimmed decline message (the model's, or the
    ///   deterministic one if it left it blank).
    /// - **Shoppable** → each part is trimmed; a part missing a label borrows its query and
    ///   vice-versa; parts with neither are dropped; duplicates (by cleaned query) collapse;
    ///   the list is capped at ``RuleBasedMissionPlanner/maxParts``. Title/subtitle/note fall
    ///   back to deterministic values when blank. If *nothing* usable survives, it degrades to
    ///   the same single-query plan as the rule-based floor — so a shoppable goal always yields
    ///   a searchable task.
    ///
    /// Pure and model-free: same draft + goal always produces the same mission.
    static func mission(from draft: MissionDraft, goal: String, tier: PlannerTier) -> PlannedMission {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        guard draft.isShoppable else {
            let decline = draft.decline.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlannedMission(
                task: nil,
                tier: tier,
                decline: decline.isEmpty ? RuleBasedMissionPlanner.declineMessage : decline
            )
        }

        let parts = cleanParts(draft.parts)
        guard !parts.isEmpty else {
            // The model said "shoppable" but gave nothing usable — fall back to the single
            // generic query, while keeping the (proven) model tier in the report.
            let title = RuleBasedMissionPlanner.title(from: trimmedGoal)
            let task = RuleBasedMissionPlanner.makeTask(
                goal: trimmedGoal,
                title: title,
                subtitle: cleanedSubtitle(draft.subtitle),
                note: cleanedNote(draft.note, parts: [title]),
                parts: [(label: title, query: RuleBasedMissionPlanner.clean(query: trimmedGoal))]
            )
            return PlannedMission(task: task, tier: tier, decline: nil)
        }

        let title = cleanedTitle(draft.title, goal: trimmedGoal)
        let task = RuleBasedMissionPlanner.makeTask(
            goal: trimmedGoal,
            title: title,
            subtitle: cleanedSubtitle(draft.subtitle),
            note: cleanedNote(draft.note, parts: parts.map(\.label)),
            parts: parts
        )
        return PlannedMission(task: task, tier: tier, decline: nil)
    }

    /// Trims each part, repairs a half-filled part (label↔query), drops the empty, dedupes by
    /// cleaned query (keeping the first), and caps the count. The list-shaping discipline that
    /// mirrors ``AppleFoundationCurator/reconcile(modelIDs:candidates:)``.
    static func cleanParts(_ raw: [PlanPartDraft]) -> [(label: String, query: String)] {
        var seen = Set<String>()
        var out: [(label: String, query: String)] = []
        for part in raw {
            let label = part.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let query = RuleBasedMissionPlanner.clean(query: part.query)
            // Repair a half-filled part rather than discard a real intent.
            let resolvedQuery = query.isEmpty ? RuleBasedMissionPlanner.clean(query: label) : query
            let resolvedLabel = label.isEmpty ? query : label
            guard !resolvedQuery.isEmpty, !resolvedLabel.isEmpty else { continue }
            guard seen.insert(resolvedQuery.lowercased()).inserted else { continue }
            out.append((label: resolvedLabel, query: resolvedQuery))
            if out.count == RuleBasedMissionPlanner.maxParts { break }
        }
        return out
    }

    private static func cleanedTitle(_ raw: String, goal: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RuleBasedMissionPlanner.title(from: goal) : trimmed
    }

    private static func cleanedSubtitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RuleBasedMissionPlanner.defaultSubtitle : trimmed
    }

    private static func cleanedNote(_ raw: String, parts: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RuleBasedMissionPlanner.curatorNote(forParts: parts) : trimmed
    }

    // MARK: Prompt construction

    /// The planner persona + this user's taste, so the decomposition leans toward what they'd
    /// actually want. Used as the session's instructions (stable across the single call).
    static func instructions(profile: TasteProfile) -> String {
        """
        You are Crumb, a personal shopping curator with a warm, plainspoken, slightly literary \
        voice. You turn a person's shopping goal into a concrete plan you can shop for.

        The user's taste:
        - Vibe: \(profile.vibe.joined(separator: ", "))
        - Leanings: \(profile.leanings.joined(separator: "; "))
        - In their words: "\(profile.signatureLine)"

        Break the goal into 3 to \(RuleBasedMissionPlanner.maxParts) concrete parts to shop for. \
        For each part give a short human label (what it is) and a concise catalog search query \
        (a few plain keywords, no punctuation) you'd type into a shop's search. Lean the plan \
        toward this person's taste, but never invent constraints they didn't imply. Keep the \
        title and subtitle short and in their intent.

        If the goal is NOT something a shop can fulfill — a question, nonsense, or a non-shopping \
        request — set isShoppable to false and write one short, friendly sentence telling them \
        you shop for things and to try a shopping goal.
        """
    }

    static func prompt(for goal: String) -> String {
        """
        The user's goal:
        "\(cappedGoal(goal))"

        Plan this mission: a short title, a short subtitle of context, a one-sentence curator \
        note framing the plan, and the parts (label + search query) to shop for.
        """
    }

    /// How many characters of the goal we feed the model. A guard rail on the *fixed* prompt
    /// cost so a pasted essay can't, by itself, eat the context window — the decomposition only
    /// needs the gist. The full goal is still used by the deterministic reconcile / fallback
    /// (title, id, single-query), so capping here never changes the rule-based plan.
    static let maxGoalChars = 600

    /// Trims the goal and, if it's longer than ``maxGoalChars``, cuts it at the last word
    /// boundary within the cap (so we never split a word). Pure — unit-tested.
    static func cappedGoal(_ goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxGoalChars else { return trimmed }
        let prefix = trimmed.prefix(maxGoalChars)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prefix)
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> PlannerTier.Fallback {
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .offlineOrError
        }
    }
}

/// The structured output of a planning call. Guided generation keeps the model returning a
/// clean, well-shaped plan rather than prose we'd have to parse; ``AppleFoundationMissionPlanner/mission(from:goal:tier:)``
/// then reconciles it into a searchable mission (or an honest decline).
@Generable
public struct MissionDraft {
    @Guide(description: "true if this is a shopping goal a shop can fulfill; false for a question, nonsense, or a non-shopping request.")
    public var isShoppable: Bool

    @Guide(description: "A short, warm mission title in the user's intent, e.g. 'Set up my pour-over corner'. Empty if not shoppable.")
    public var title: String

    @Guide(description: "A brief subtitle of context or constraints, e.g. 'Slower mornings · better cup'. Empty if not shoppable.")
    public var subtitle: String

    @Guide(description: "One short sentence in Crumb's curator voice framing the plan. No emoji or exclamation marks. Empty if not shoppable.")
    public var note: String

    @Guide(description: "The mission broken into 3 to 6 concrete parts to shop for. Empty if not shoppable.")
    public var parts: [PlanPartDraft]

    @Guide(description: "If not shoppable, one short friendly sentence saying you shop for things and to try a shopping goal. Empty otherwise.")
    public var decline: String

    public init(
        isShoppable: Bool,
        title: String,
        subtitle: String,
        note: String,
        parts: [PlanPartDraft],
        decline: String
    ) {
        self.isShoppable = isShoppable
        self.title = title
        self.subtitle = subtitle
        self.note = note
        self.parts = parts
        self.decline = decline
    }
}

/// One part of a planned mission: a human label and the catalog query that finds it.
@Generable
public struct PlanPartDraft {
    @Guide(description: "A short label for this part, e.g. 'Gooseneck kettle'.")
    public var label: String

    @Guide(description: "A concise catalog search query of a few plain keywords, e.g. 'gooseneck kettle'. No punctuation.")
    public var query: String

    public init(label: String, query: String) {
        self.label = label
        self.query = query
    }
}
