import Foundation
import FoundationModels

/// The "real" chip suggester, built on Apple's Foundation Models — it reads the mission and this
/// user's taste to propose quick-refinement chips that fit, rather than a fixed gear-oriented row.
/// It mirrors ``AppleFoundationRefinementInterpreter`` exactly: ``RuleBasedRefineChipSuggester``
/// stays the offline floor, and one guided `@Generable` call proposes the chips.
///
/// ## Tiers & degrade order (same story as the curator/planner/interpreter)
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — gated behind
///    `CRUMB_PCC_ENABLED` because *constructing or querying* that type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process (an uncatchable
///    fatal error, not a throw). See the identical gate in ``AppleFoundationCurator``.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, no entitlement, the working
///    primary today.
/// 3. **Rule-based** — ``RuleBasedRefineChipSuggester``'s category taxonomy, used when neither
///    model is usable (always the case on the simulator/CI and in headless screenshots).
///
/// The model's draft is folded back by the pure, unit-tested ``reconcile(draft:floor:)``, which
/// trims, dedupes, and caps it and — crucially — **falls back to the deterministic floor when the
/// model returns a thin or empty set**, so the bar is never left with one lonely chip.
public struct AppleFoundationRefineChipSuggester: RefineChipSuggester {

    /// The deterministic floor: the degrade target and the source of the shown-instantly chips.
    private let rule = RuleBasedRefineChipSuggester()

    public init() {}

    public func chips(for mission: ShoppingTask, profile: TasteProfile) async -> [RefineChip] {
        let floor = RuleBasedRefineChipSuggester.chips(for: mission)

        // Tier 1 — Private Cloud Compute, gated behind `CRUMB_PCC_ENABLED` for the entitlement-trap
        // reason (see the curator): constructing/querying the type without the entitlement traps.
        #if CRUMB_PCC_ENABLED
        let pcc = PrivateCloudComputeLanguageModel()
        if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
            if let chips = try? await suggest(mission, profile, model: pcc, deepReasoning: true, floor: floor) {
                return chips
            }
            // Suggestion probe failed (offline / transient) — fall through to on-device.
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        guard case .available = device.availability else { return floor }
        guard let chips = try? await suggest(mission, profile, model: device, deepReasoning: false, floor: floor) else {
            return floor
        }
        return chips
    }

    // MARK: Suggest

    /// Proposing chips is a short, near-deterministic task — run it cool.
    static let temperature = 0.4

    /// One guided generation reads the mission into a ``RefineChipDraft``, which the pure
    /// ``reconcile(draft:floor:)`` folds into clean chips. Throws when the call fails, so the tier
    /// cascade / floor in ``chips(for:profile:)`` takes over.
    private func suggest<M: LanguageModel>(
        _ mission: ShoppingTask,
        _ profile: TasteProfile,
        model: M,
        deepReasoning: Bool,
        floor: [RefineChip]
    ) async throws -> [RefineChip] {
        let session = Self.chipSession(profile: profile, mission: mission, floor: floor, model: model, deepReasoning: deepReasoning)
        let response = try await session.respond(to: Self.prompt, generating: RefineChipDraft.self)
        return Self.reconcile(draft: response.content, floor: floor)
    }

    /// Builds the suggestion session: ``ChipSuggesterInstructions`` in a profile that declares the
    /// tuning + context policy. The deterministic `floor` chips are handed to the instructions as
    /// the category anchor, so a weak on-device model refines them for this specific mission rather
    /// than drifting to another category. Reasoning is applied only on the deep-reasoning (PCC) tier
    /// — the on-device model rejects `.reasoningLevel`. Mirrors the interpreter's `refineSession`.
    static func chipSession<M: LanguageModel>(
        profile: TasteProfile,
        mission: ShoppingTask,
        floor: [RefineChip],
        model: M,
        deepReasoning: Bool
    ) -> LanguageModelSession {
        let base = LanguageModelSession.Profile { ChipSuggesterInstructions(profile: profile, mission: mission, floor: floor) }
            .model(model)
            .temperature(temperature)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
    }

    // MARK: Reconcile (pure — the unit-tested guarantee behind the model call)

    /// Folds the model's ``RefineChipDraft`` into clean chips that are always safe to show: labels
    /// and texts are zipped by index, trimmed, dropped when either side is blank, deduped by slug,
    /// and capped at ``maxChips``. A draft that yields fewer than ``minChips`` usable chips falls
    /// back to the deterministic `floor` rather than showing a lonely one or two. Finally, a price
    /// lever is guaranteed: the on-device model reliably *drops* "Cheaper" despite the instruction,
    /// so if none survived we graft the floor's price chip back in (the design's standing promise).
    ///
    /// Pure and model-free: same draft always produces the same chips.
    static func reconcile(draft: RefineChipDraft, floor: [RefineChip]) -> [RefineChip] {
        var seen = Set<String>()
        var out: [RefineChip] = []
        let pairCount = min(draft.labels.count, draft.refinementTexts.count)
        for index in 0..<pairCount {
            let label = normalizedLabel(draft.labels[index])
            let text = draft.refinementTexts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !text.isEmpty else { continue }
            let id = RefineChip.slug(label)
            guard seen.insert(id).inserted else { continue }
            out.append(RefineChip(id: id, label: label, refinementText: text))
            if out.count == maxChips { break }
        }
        guard out.count >= minChips else { return floor }
        return withPriceLever(out, floor: floor)
    }

    /// Ensures the chip row carries a price lever. If the model kept one, returns `chips` as-is;
    /// otherwise appends the floor's price chip (every category taxonomy defines one), trimming the
    /// weakest tail chip first when the row is already full so it stays one scannable line.
    static func withPriceLever(_ chips: [RefineChip], floor: [RefineChip]) -> [RefineChip] {
        guard !chips.contains(where: isPriceLever), let price = floor.first(where: isPriceLever) else {
            return chips
        }
        var out = chips
        if out.count >= maxChips { out.removeLast() }
        out.append(price)
        return out
    }

    /// Trims a model label and, when it comes back SHOUTING (all-caps, as the on-device model
    /// often does), softens it to the sentence case the deterministic floor uses ("MERINO" →
    /// "Merino", "CAFFEINE-FREE" → "Caffeine-free"). Labels the model already cased sensibly
    /// ("Caffeine-free", "Loose leaf") are left untouched.
    static func normalizedLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == trimmed.uppercased(), trimmed != trimmed.lowercased() else { return trimmed }
        return String(trimmed.prefix(1)) + trimmed.dropFirst().lowercased()
    }

    /// A chip is a price lever when its directive would move price (its id or text says "cheaper").
    static func isPriceLever(_ chip: RefineChip) -> Bool {
        chip.id == "cheaper" || chip.refinementText.lowercased().contains("cheaper")
    }

    /// The most chips the bar shows — keeps the row to a single, scannable line.
    static let maxChips = 4
    /// Below this, a model result is too thin to trust; use the deterministic floor instead.
    static let minChips = 2

    // MARK: Prompt

    static let prompt = """
        Suggest 3 to 4 quick "refine" chips for this mission — the one-tap shortcuts shown under a \
        deck of curated products so the user can nudge it. Start from the baseline chips in your \
        instructions and keep or sharpen them for THIS specific mission; stay in the same spirit as \
        the baseline and never drift to a different kind of product. Always keep a price lever. Keep \
        labels one or two words, Title Case, and give each the short sentence a tap submits.
        """
}

/// The chip-suggester instructions: the shared Crumb persona + the propose-chips role + this
/// user's taste + the mission. The dynamic-session instructions for the suggester, mirroring
/// ``RefinerInstructions``.
struct ChipSuggesterInstructions: DynamicInstructions {
    let profile: TasteProfile
    let mission: ShoppingTask
    /// The deterministic category chips, handed to the model as the anchor it refines — the guard
    /// that keeps a weak on-device model from drifting to another category's chips.
    let floor: [RefineChip]

    var body: some DynamicInstructions {
        CrumbPersona(recipient: nil)
        Instructions("The user is looking at a curated deck of products for a mission. Propose the quick one-tap 'refine' chips that best fit this mission so they can nudge the deck.")
        TasteBlock(profile: profile, recipient: nil, includeBudget: false)
        MissionBlock(mission: mission)
        Instructions(anchor)
        Instructions(Self.guide)
    }

    /// States the baseline chips (already category-correct) as the thing to refine, not replace —
    /// so "warmer/durable" gear chips never surface for a drink, and drink chips never surface for
    /// gear, even when the on-device model is weak.
    private var anchor: String {
        let baseline = floor.map(\.label).joined(separator: ", ")
        return """
            These baseline chips already fit this mission's category: \(baseline). Keep them, or \
            reword them to fit THIS mission more precisely, but do not switch to a different \
            category of product. If you can't improve on a baseline chip, return it as-is.
            """
    }

    /// How to fill the chips. Pure — the reconcile that follows enforces the shape regardless.
    /// Examples span categories on purpose, so the model isn't biased toward any one of them.
    static let guide = """
        Return two parallel arrays of the same length (3–4 entries):
        - labels: short chip titles, Title Case, one or two words (e.g. "Cheaper", "Warmer", \
        "Caffeine-free", "Natural").
        - refinementTexts: for each label, the sentence a tap submits — the plain words a person \
        would type (e.g. "warmer tones and materials"). Same count and order as labels.
        Always include a price lever ("Cheaper"). Never invent constraints the mission doesn't \
        imply. Keep everything short.
        """
}

/// The structured output of a chip-suggestion call. Two parallel arrays (labels + the sentence
/// each tap submits) keep the model on the same known-good shape as ``RefinementDraft``'s string
/// arrays; ``AppleFoundationRefineChipSuggester/reconcile(draft:floor:)`` then zips and cleans them.
@Generable
public struct RefineChipDraft {
    @Guide(description: "3 to 4 short chip labels that fit this mission, Title Case, one or two words each. Refine the baseline chips from the instructions; do not switch product category.")
    public var labels: [String]

    @Guide(description: "For each label, in the same order, the refinement sentence a tap submits — the plain words a person would type, e.g. 'warmer tones and materials'. Same count as labels.")
    public var refinementTexts: [String]

    public init(labels: [String], refinementTexts: [String]) {
        self.labels = labels
        self.refinementTexts = refinementTexts
    }
}
