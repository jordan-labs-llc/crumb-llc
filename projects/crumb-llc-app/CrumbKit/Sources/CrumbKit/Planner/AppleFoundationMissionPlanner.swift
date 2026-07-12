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

        // Tier 1 — Private Cloud Compute, gated behind `CRUMB_PCC_ENABLED` for the same
        // entitlement-trap reason as the curator: *constructing or querying* the type without the
        // entitlement traps the process (an uncatchable fatal error, not a throw).
        #if CRUMB_PCC_ENABLED
        let pcc = PrivateCloudComputeLanguageModel()
        if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
            if let planned = await attemptDecompose(trimmed, profile, model: pcc, deepReasoning: true, tier: .privateCloud) {
                return planned
            }
            // Planning probe failed (offline / transient) — fall through to on-device.
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            if let planned = await attemptDecompose(trimmed, profile, model: device, deepReasoning: false, tier: .onDevice) {
                return planned
            }
            return RuleBasedMissionPlanner.plan(goal: trimmed, reason: .offlineOrError)
        case let .unavailable(reason):
            return RuleBasedMissionPlanner.plan(goal: trimmed, reason: Self.map(reason))
        }
    }

    // MARK: Decompose

    /// The on-device model's context window is 4096 tokens; the transcript is *instructions +
    /// prompt + the model's generated plan*. Left unbounded, an occasional runaway generation
    /// pushes the transcript past 4096 and `respond(generating:)` throws
    /// `GenerationError.exceededContextWindowSize` — the very error `try?` used to swallow into a
    /// single-query fallback. We now bound the response on the session's `Profile` via
    /// `.maximumResponseTokens` (a *declared* policy, not an inline `GenerationOptions` band-aid)
    /// and pair it with `.transcriptErrorHandlingPolicy(.revertTranscript)`. A normal
    /// ``MissionDraft`` plan is well under the cap, so bounding can't truncate a real plan; it only
    /// fences off the runaway. The bound is derived from the live model's real context window via
    /// ``TokenBudget`` (#37) — 1024 on a 4096-token device, larger on a bigger window. The fixed
    /// prompt cost is kept small by ``cappedGoal(_:)``.
    /// Planning wants structure with a little creative latitude in labels — cooler than the recap,
    /// warmer than the parse seams.
    static let temperature = 0.55

    /// Runs the planning probe with a single retry, **logging** (not silently swallowing) a
    /// thrown error. With default sampling a second generation is usually shorter, so a transient
    /// near-the-limit overflow recovers rather than degrading the user to the single-query floor.
    /// Returns `nil` only when both attempts throw — the caller then cascades / degrades.
    private func attemptDecompose<M: LanguageModel & ContextWindowProviding>(
        _ goal: String,
        _ profile: TasteProfile,
        model: M,
        deepReasoning: Bool,
        tier: PlannerTier
    ) async -> PlannedMission? {
        do {
            return try await decompose(goal, profile, model: model, deepReasoning: deepReasoning, tier: tier)
        } catch {
            Self.log.error("Planner generation threw (attempt 1, retrying): \(error.localizedDescription, privacy: .public)")
            do {
                return try await decompose(goal, profile, model: model, deepReasoning: deepReasoning, tier: tier)
            } catch {
                Self.log.error("Planner generation threw (attempt 2, degrading to rule-based): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// One guided generation reads the goal into a ``MissionDraft``, which the pure
    /// ``mission(from:goal:tier:)`` folds into a searchable mission. Throws when the call fails,
    /// so the tier cascade / rule-based fallback in ``plan(goal:profile:)`` takes over. The
    /// response bound + context policy live on the session's profile (see ``planSession``), so a
    /// runaway generation can't overflow the context window.
    private func decompose<M: LanguageModel & ContextWindowProviding>(
        _ goal: String,
        _ profile: TasteProfile,
        model: M,
        deepReasoning: Bool,
        tier: PlannerTier
    ) async throws -> PlannedMission {
        let session = Self.planSession(profile: profile, model: model, deepReasoning: deepReasoning)
        let response = try await session.respond(
            to: Self.prompt(for: goal),
            generating: MissionDraft.self
        )
        return Self.mission(from: response.content, goal: goal, tier: tier)
    }

    /// Builds the planning session: ``PlannerInstructions`` in a profile that selects the tier's
    /// model and declares the planning tuning + context policy. Reasoning is applied only on the
    /// deep-reasoning (PCC) tier — the on-device model rejects `.reasoningLevel`.
    static func planSession<M: LanguageModel & ContextWindowProviding>(
        profile: TasteProfile,
        model: M,
        deepReasoning: Bool
    ) -> LanguageModelSession {
        let base = LanguageModelSession.Profile { PlannerInstructions(profile: profile) }
            .model(model)
            .temperature(temperature)
            .maximumResponseTokens(TokenBudget(model: model).plannerMaxResponseTokens)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
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

        // Honor the altitude flag deterministically: a single-item goal is collapsed to its one
        // core part even if the model over-produced accessories, so tightness never depends on the
        // model obeying the instruction. A broad goal keeps its (already capped) complementary parts.
        let cleaned = cleanParts(draft.parts)
        let parts = draft.isSingleItem ? Array(cleaned.prefix(1)) : cleaned

        // Sports player-kit floor (#68): a recognized sport-gear goal is a multi-part safety/fit kit,
        // never one product. When the model under-decomposes it — single-item framing, or fewer than
        // two parts — reconcile to the deterministic player-kit expansion (with its stated, editable
        // assumption) so a high-school lacrosse kit reaches the deck as a real kit, not a lone stick.
        // Only fires for a recognized sport, so every other goal keeps the model's own decomposition.
        if let kit = RuleBasedMissionPlanner.sportsKit(for: trimmedGoal),
           draft.isSingleItem || parts.count < 2 {
            let task = RuleBasedMissionPlanner.makeTask(
                goal: trimmedGoal,
                title: cleanedTitle(draft.title, goal: trimmedGoal),
                subtitle: cleanedSubtitle(draft.subtitle, goal: trimmedGoal),
                note: kit.note,
                parts: kit.parts,
                isSingleItem: false
            )
            return PlannedMission(task: task, tier: tier, decline: nil)
        }

        // Direct product/category floor (#84): when the user's own goal is a short product query,
        // reconcile away model drift into accessories or setup language. If the model kept an on-goal
        // part, keep that single part; if it only returned equipment/vessels, fall back to the user's
        // exact product query so "premium jasmine tea" cannot become "teapot".
        if let direct = directProductOverride(parts: parts, goal: trimmedGoal) {
            let task = RuleBasedMissionPlanner.makeTask(
                goal: trimmedGoal,
                title: direct.useGoalDefaults
                    ? RuleBasedMissionPlanner.title(from: trimmedGoal)
                    : cleanedTitle(draft.title, goal: trimmedGoal),
                subtitle: direct.useGoalDefaults
                    ? RuleBasedMissionPlanner.defaultSubtitle
                    : cleanedSubtitle(draft.subtitle, goal: trimmedGoal),
                note: direct.useGoalDefaults
                    ? RuleBasedMissionPlanner.curatorNote(forParts: direct.parts.map(\.label))
                    : cleanedNote(draft.note, parts: direct.parts.map(\.label), goal: trimmedGoal),
                parts: direct.parts,
                isSingleItem: true
            )
            return PlannedMission(task: task, tier: tier, decline: nil)
        }

        guard !parts.isEmpty else {
            // The model said "shoppable" but gave nothing usable — fall back to the single
            // generic query, while keeping the (proven) model tier in the report.
            let title = RuleBasedMissionPlanner.title(from: trimmedGoal)
            let task = RuleBasedMissionPlanner.makeTask(
                goal: trimmedGoal,
                title: title,
                subtitle: cleanedSubtitle(draft.subtitle, goal: trimmedGoal),
                note: cleanedNote(draft.note, parts: [title], goal: trimmedGoal),
                parts: [(label: title, query: RuleBasedMissionPlanner.clean(query: trimmedGoal))],
                // No usable parts survived, so this is the single generic query — honor the model's
                // altitude call for framing (it still said shoppable).
                isSingleItem: draft.isSingleItem
            )
            return PlannedMission(task: task, tier: tier, decline: nil)
        }

        let title = cleanedTitle(draft.title, goal: trimmedGoal)
        let task = RuleBasedMissionPlanner.makeTask(
            goal: trimmedGoal,
            title: title,
            subtitle: cleanedSubtitle(draft.subtitle, goal: trimmedGoal),
            note: cleanedNote(draft.note, parts: parts.map(\.label), goal: trimmedGoal),
            parts: parts,
            // The model's altitude judgment — the same flag that collapsed to one part above.
            isSingleItem: draft.isSingleItem
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

    static func directProductOverride(
        parts: [(label: String, query: String)],
        goal: String
    ) -> (parts: [(label: String, query: String)], useGoalDefaults: Bool)? {
        let goalQuery = RuleBasedMissionPlanner.clean(query: goal)
        guard RuleBasedMissionPlanner.isSingleItem(goal: goalQuery), !goalQuery.isEmpty else { return nil }
        let title = RuleBasedMissionPlanner.title(from: goalQuery)
        for part in parts {
            guard !hasAccessoryDrift(part.label + " " + part.query, goal: goalQuery) else { continue }
            let labelOK = preservesDirectProductText(part.label, goal: goalQuery)
            let queryOK = preservesDirectProductText(part.query, goal: goalQuery)
            if labelOK {
                return (
                    parts: [(label: part.label, query: queryOK ? part.query : goalQuery)],
                    useGoalDefaults: !queryOK
                )
            }
            if queryOK {
                return (parts: [(label: title, query: part.query)], useGoalDefaults: true)
            }
        }
        return (parts: [(label: title, query: goalQuery)], useGoalDefaults: true)
    }

    static func preservesDirectProduct(_ part: (label: String, query: String), goal: String) -> Bool {
        let partText = part.label + " " + part.query
        guard !hasAccessoryDrift(partText, goal: goal) else { return false }
        return preservesDirectProductText(partText, goal: goal)
    }

    private static func preservesDirectProductText(_ text: String, goal: String) -> Bool {
        let goalTokens = Set(RuleBasedRelevanceGate.orderedTokens(goal)
            .filter { !RuleBasedRelevanceGate.genericQualifiers.contains($0) })
        guard !goalTokens.isEmpty else { return false }
        let textTokens = RuleBasedRelevanceGate.tokens(text)
        let core = RuleBasedRelevanceGate.distinctiveTerms(in: goal)
        let requiredOverlap = core.isEmpty ? goalTokens : core
        return !textTokens.isDisjoint(with: requiredOverlap)
    }

    private static func hasAccessoryDrift(_ text: String, goal: String) -> Bool {
        let goalTokens = Set(RuleBasedRelevanceGate.orderedTokens(goal)
            .filter { !RuleBasedRelevanceGate.genericQualifiers.contains($0) })
        let words = rawWords(text)
        let driftWords = accessoryDriftWords.subtracting(goalTokens)
        return !words.isDisjoint(with: driftWords)
    }

    private static func rawWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static let accessoryDriftWords: Set<String> = [
        "brewer", "brewers", "caddy", "caddies", "canister", "canisters", "cup", "cups",
        "equipment", "gear", "infuser", "infusers", "kettle", "kettles", "kit", "kits",
        "mug", "mugs", "pitcher", "pitchers", "pot", "pots", "scoop", "scoops", "server",
        "servers", "set", "sets", "setup", "spoon", "spoons", "strainer", "strainers",
        "teapot", "teapots", "vessel", "vessels", "whisk", "whisks",
    ]

    private static func cleanedTitle(_ raw: String, goal: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || isLeakedExemplar(trimmed, goal: goal))
            ? RuleBasedMissionPlanner.title(from: goal) : trimmed
    }

    private static func cleanedSubtitle(_ raw: String, goal: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || isLeakedExemplar(trimmed, goal: goal))
            ? RuleBasedMissionPlanner.defaultSubtitle : trimmed
    }

    private static func cleanedNote(_ raw: String, parts: [String], goal: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || isLeakedExemplar(trimmed, goal: goal))
            ? RuleBasedMissionPlanner.curatorNote(forParts: parts) : trimmed
    }

    // MARK: - Exemplar-leak guard (#23)

    /// Seed-mission metadata the planner must never pass off as its *own* output for an unrelated
    /// goal. The seed missions double as the on-device model's few-shot anchors, and the small model
    /// will parrot a vivid one — the coffee subtitle "Slower mornings · better cup" — straight onto a
    /// "premium jasmine tea" plan. Normalized (lowercased, punctuation → spaces) so a lightly-reworded
    /// copy still matches. Built from ``SeedData/missions`` so it stays in sync as the seeds change.
    static let reservedExemplars: Set<String> = Set(
        SeedData.missions
            .flatMap { [$0.title, $0.subtitle, $0.curatorNote] }
            .map(normalizeExemplar)
    )

    /// The matching key for ``reservedExemplars``: lowercased, punctuation-stripped, whitespace-
    /// collapsed. Pure.
    static func normalizeExemplar(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// Whether `text` is a seed exemplar **leaking onto an unrelated goal**: it matches a seed
    /// mission's title/subtitle/note *and* shares no significant word with the goal. The two-part
    /// test is deliberate — a field that genuinely fits the goal (a pour-over title for a pour-over
    /// goal) matches a seed but shares a word, so it is kept; only an off-topic copy is dropped for
    /// the goal-derived deterministic default. Pure — unit-tested.
    static func isLeakedExemplar(_ text: String, goal: String) -> Bool {
        guard reservedExemplars.contains(normalizeExemplar(text)) else { return false }
        return RuleBasedRelevanceGate.tokens(text).isDisjoint(with: RuleBasedRelevanceGate.tokens(goal))
    }

    // MARK: Prompt construction

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

/// The planner instructions: the shared Crumb persona + the decomposition role + this user's taste
/// + how to break the goal into searchable parts (or decline). The dynamic-session replacement for
/// the planner's old hand-built instruction string, composed from the shared ``CrumbPersona`` /
/// ``TasteBlock`` blocks plus a planner-specific role + guide leaf.
struct PlannerInstructions: DynamicInstructions {
    let profile: TasteProfile

    var body: some DynamicInstructions {
        CrumbPersona(recipient: nil)
        Instructions("You turn a person's shopping goal into a concrete plan you can shop for.")
        TasteBlock(profile: profile, recipient: nil, includeBudget: false)
        Instructions(Self.guide)
    }

    /// The decomposition + decline guidance. Pure — unit-tested.
    static let guide = """
        Break the goal into the parts to shop for, each with a short human label (what it is) and \
        a concise catalog search query (a few plain keywords, no punctuation) you'd type into a \
        shop's search. Match the plan to the goal's altitude: when the goal names ONE specific \
        item, return exactly one part and set isSingleItem to true — never pad it with accessories \
        or extras they didn't ask for. Only when the goal is to outfit a space or an activity that \
        genuinely needs several complementary things, break it into up to \
        \(RuleBasedMissionPlanner.maxParts) parts and set isSingleItem to false.

        A goal for "gear", "equipment", "kit", or "supplies" (e.g. "premium lacrosse gear", \
        "ski equipment") is ALWAYS a complete multi-part kit, never one item: enumerate the real \
        pieces someone needs for that pursuit (for a sport: the stick/implement, protective pads, \
        helmet or eyewear, gloves, footwear, mouthguard, a bag), each as its own part with a \
        specific query — never a single generic part like "collar". For protective or technical \
        gear, let fit, safety, and completeness drive the parts; do NOT apply apparel/aesthetic \
        taste language (fabrics, colors, "quiet", "muted") to equipment that is chosen for function.

        Let this person's taste guide which style of thing you'd pick within a part, but never add \
        parts or constraints they didn't imply. Keep the title and subtitle short and in their intent.

        If the goal is NOT something a shop can fulfill — a question, nonsense, or a non-shopping \
        request — set isShoppable to false and write one short, friendly sentence telling them \
        you shop for things and to try a shopping goal.
        """
}

/// The structured output of a planning call. Guided generation keeps the model returning a
/// clean, well-shaped plan rather than prose we'd have to parse; ``AppleFoundationMissionPlanner/mission(from:goal:tier:)``
/// then reconciles it into a searchable mission (or an honest decline).
@Generable
public struct MissionDraft {
    @Guide(description: "true if this is a shopping goal a shop can fulfill; false for a question, nonsense, or a non-shopping request.")
    public var isShoppable: Bool

    @Guide(description: "true ONLY if the goal names ONE specific item to buy (e.g. 'premium jasmine tea', 'a cast iron skillet'). false if it needs several complementary things: outfitting a space or activity ('set up my pour-over corner'), OR any 'gear', 'equipment', 'kit', or 'supplies' goal ('premium lacrosse gear', 'ski equipment', 'camping gear') — those are complete multi-part kits, never one item.")
    public var isSingleItem: Bool

    @Guide(description: "A short, warm mission title in the user's own words, drawn from THIS goal specifically — not a generic or example phrase. Empty if not shoppable.")
    public var title: String

    @Guide(description: "A brief subtitle: a few words of context for THIS goal — its occasion, setting, or constraints. Draw it from the goal, not an example. Empty if not shoppable.")
    public var subtitle: String

    @Guide(description: "One short sentence in Crumb's curator voice framing the plan. No emoji or exclamation marks. Empty if not shoppable.")
    public var note: String

    @Guide(description: "The parts to shop for: exactly ONE when isSingleItem is true, otherwise up to 6 concrete complementary parts. Empty if not shoppable.")
    public var parts: [PlanPartDraft]

    @Guide(description: "If not shoppable, one short friendly sentence saying you shop for things and to try a shopping goal. Empty otherwise.")
    public var decline: String

    public init(
        isShoppable: Bool,
        isSingleItem: Bool = false,
        title: String,
        subtitle: String,
        note: String,
        parts: [PlanPartDraft],
        decline: String
    ) {
        self.isShoppable = isShoppable
        self.isSingleItem = isSingleItem
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
