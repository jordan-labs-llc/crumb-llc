import Foundation
import FoundationModels

/// The "real" taste extractor, built on Apple's Foundation Models — the input twin of
/// ``AppleFoundationCurator``. One guided `@Generable` call reads a free-text self-
/// description into a structured ``TasteProfile``.
///
/// ## Tiers & degrade order (same story as the curator)
/// 1. **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`, OS 27+) — gated behind
///    `CRUMB_PCC_ENABLED` because *constructing or querying* that type without the
///    `com.apple.developer.private-cloud-compute` entitlement traps the process (an
///    uncatchable fatal error, not a throw). See the identical gate in ``AppleFoundationCurator``.
/// 2. **On-device** (`SystemLanguageModel.default`) — offline, no entitlement, the working
///    primary today.
/// 3. **Manual** — return `nil`; the caller keeps the user's hand-set chips/slider. There is
///    no deterministic "rule-based parse" floor (free text is too open to guess safely), so
///    an unavailable model simply means manual capture.
///
/// Merging is conservative: a field the model leaves empty falls back to `base`, the budget
/// is clamped to `0…1`, and chip lists are trimmed/deduped/capped — so a vague sentence tops
/// up the defaults rather than wiping them, and a hallucinated number can't escape range.
public struct AppleFoundationTasteExtractor: TasteExtractor {

    public init() {}

    public func extract(from text: String, base: TasteProfile) async -> TasteProfile? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Tier 1 — Private Cloud Compute, gated behind `CRUMB_PCC_ENABLED` for the entitlement-trap
        // reason (see the curator): constructing/querying the type without the entitlement traps.
        #if CRUMB_PCC_ENABLED
        let pcc = PrivateCloudComputeLanguageModel()
        if case .available = pcc.availability, !pcc.quotaUsage.isLimitReached {
            if let parsed = try? await parse(trimmed, base: base, model: pcc, deepReasoning: true) {
                return parsed
            }
            // Parse failed (offline / transient) — fall through to on-device.
        }
        #endif

        // Tier 2 — on-device.
        let device = SystemLanguageModel.default
        guard case .available = device.availability else { return nil }
        return try? await parse(trimmed, base: base, model: device, deepReasoning: false)
    }

    // MARK: Parse

    /// Distilling a description into a structured profile is a faithful extraction, not a creative
    /// task — run it cool.
    static let temperature = 0.3
    /// A comfortable response bound (the parsed profile is a handful of chips + a number + a line),
    /// declared on the session's `Profile` for context safety.
    static let maxResponseTokens = 512

    /// One guided generation reads the description into ``ExtractedTaste``, which we then
    /// reconcile against `base`. Throws when the call fails, so the tier cascade / `nil`
    /// fallback in ``extract(from:base:)`` takes over.
    private func parse<M: LanguageModel>(
        _ text: String,
        base: TasteProfile,
        model: M,
        deepReasoning: Bool
    ) async throws -> TasteProfile {
        let session = Self.extractSession(model: model, deepReasoning: deepReasoning)
        let response = try await session.respond(
            to: Self.prompt(for: text),
            generating: ExtractedTaste.self
        )
        return Self.merge(response.content, into: base)
    }

    /// Builds the extraction session: ``ExtractorInstructions`` in a profile that declares the
    /// parse tuning + context policy. Reasoning is applied only on the deep-reasoning (PCC) tier —
    /// the on-device model rejects `.reasoningLevel`.
    static func extractSession<M: LanguageModel>(model: M, deepReasoning: Bool) -> LanguageModelSession {
        let base = LanguageModelSession.Profile { ExtractorInstructions() }
            .model(model)
            .temperature(temperature)
            .maximumResponseTokens(maxResponseTokens)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        if deepReasoning {
            return LanguageModelSession(profile: base.reasoningLevel(.deep))
        }
        return LanguageModelSession(profile: base)
    }

    /// Folds the model's reading onto `base`: empty fields keep the base value, budget is
    /// clamped to `0…1`, chip lists are trimmed/deduped/capped. Pure and model-free — this is
    /// the unit-tested guarantee that a parse can only top up, never corrupt, a profile.
    static func merge(_ extracted: ExtractedTaste, into base: TasteProfile) -> TasteProfile {
        let vibe = clean(extracted.vibe)
        let leanings = clean(extracted.leanings)
        let signature = extracted.signatureLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return TasteProfile(
            vibe: vibe.isEmpty ? base.vibe : vibe,
            leanings: leanings.isEmpty ? base.leanings : leanings,
            budgetComfort: min(1, max(0, extracted.budgetComfort)),
            signatureLine: signature.isEmpty ? base.signatureLine : signature
        )
    }

    /// Trims, drops blanks, dedupes case-insensitively (keeping first spelling), and caps the
    /// list so a runaway generation can't flood the chip rows.
    static func clean(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            out.append(value)
            if out.count == maxChips { break }
        }
        return out
    }

    /// Cap on chips per row — keeps the parsed profile to a readable handful.
    static let maxChips = 6

    // MARK: Prompt construction

    static func prompt(for text: String) -> String {
        """
        Here is how the user describes their taste:
        "\(text)"

        Extract their vibe words, their leanings (preferences and trade-offs), a budget \
        comfort from 0 to 1, and a one-line signature that captures their philosophy.
        """
    }
}

/// The taste-extractor instructions. Unlike the other seams these carry no runtime state — the
/// description being parsed lives in the *prompt*, not the instructions — so the block is a single
/// fixed leaf. The dynamic-session win here is the `Profile` (tuning + context policy); the value of
/// the block form is consistency with the other five seams.
struct ExtractorInstructions: DynamicInstructions {
    var body: some DynamicInstructions {
        Instructions(Self.text)
    }

    /// The extraction guidance. Pure — unit-tested.
    static let text = """
        You read a person's short description of their shopping taste and distill it into a \
        structured profile. Be faithful — extract only what they actually say or clearly \
        imply; do not invent preferences they didn't express. Keep each vibe and leaning to \
        a few words. For budget comfort, map their words to 0.0 (very thrifty) through 1.0 \
        (happy to splurge), defaulting near 0.5 when they don't say. Write the signature line \
        in their own spirit, one short sentence, no quotes.
        """
}

/// The structured output of a taste parse. Guided generation keeps the model returning clean
/// lists + a bounded number rather than prose we'd have to parse; ``AppleFoundationTasteExtractor/merge(_:into:)``
/// then reconciles it conservatively against the user's current profile.
@Generable
struct ExtractedTaste {
    @Guide(description: "A few short vibe words, e.g. Quiet, Earthy, Built to last.")
    var vibe: [String]

    @Guide(description: "Short preferences or trade-offs, e.g. Merino over synthetic; Muted tones.")
    var leanings: [String]

    @Guide(description: "Budget comfort from 0.0 (very thrifty) to 1.0 (happy to splurge).")
    var budgetComfort: Double

    @Guide(description: "One short sentence in the user's spirit capturing their taste philosophy. No quotation marks.")
    var signatureLine: String
}
