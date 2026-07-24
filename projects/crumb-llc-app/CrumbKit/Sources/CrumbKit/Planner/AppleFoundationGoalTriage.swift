import Foundation
import FoundationModels
import os

/// The model-backed goal triage: one cheap guided call that judges `isShoppable` +
/// `isSingleItem` — the two judgments direct missions still want from a model after the upfront
/// plan decomposition was removed. Mirrors ``AppleFoundationRelevanceGate``'s shape: on-device
/// only, a tiny bounded generation, and any failure degrades silently to the deterministic
/// ``RuleBasedGoalTriage`` heuristics (reporting *why*, like every other seam).
///
/// Why a model at all: the word-cue heuristics mis-frame in both directions — "dorm room
/// refresh" reads as one product (no kit cue fires) and "sourdough starter kit" reads as a kit
/// (the " kit" cue fires on a product whose *name* contains "kit"). The judgment call is
/// sub-second because the output is two booleans, not a decomposition artifact — exactly the
/// distinction the direct-missions evaluation drew: the on-device model is good at judgments and
/// tool-driving, bad at emitting upfront plans.
public struct AppleFoundationGoalTriage: GoalTriage {

    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "GoalTriage")

    public init() {}

    /// A classification, not a creative task — run cold.
    static let temperature = 0.1
    /// Two booleans; bounded well under any window so a runaway generation can't overflow.
    static let maxResponseTokens = 256

    public func judge(_ goal: String) async -> GoalJudgment {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RuleBasedGoalTriage.judge(trimmed, reason: nil) }

        let device = SystemLanguageModel.default
        switch device.availability {
        case .available:
            do {
                let session = Self.triageSession(model: device)
                let response = try await session.respond(
                    to: Self.prompt(for: trimmed),
                    generating: GoalJudgmentDraft.self
                )
                return GoalJudgment(
                    isShoppable: response.content.isShoppable,
                    isSingleItem: response.content.isSingleItem,
                    tier: .onDevice
                )
            } catch {
                Self.log.error("Goal triage threw, degrading to heuristics: \(error.localizedDescription, privacy: .public)")
                return RuleBasedGoalTriage.judge(trimmed, reason: .offlineOrError)
            }
        case let .unavailable(reason):
            return RuleBasedGoalTriage.judge(trimmed, reason: Self.map(reason))
        }
    }

    /// Builds the triage session: ``TriageInstructions`` in a profile declaring the tuning +
    /// context policy (the same shape as every other single-shot seam).
    static func triageSession(model: SystemLanguageModel) -> LanguageModelSession {
        let profile = LanguageModelSession.Profile { TriageInstructions() }
            .model(model)
            .temperature(temperature)
            .maximumResponseTokens(maxResponseTokens)
            .historyTransform { CrumbContext.trimmed($0) }
            .transcriptErrorHandlingPolicy(.revertTranscript)
        return LanguageModelSession(profile: profile)
    }

    static func prompt(for goal: String) -> String {
        """
        The user's goal:
        "\(AppleFoundationMissionPlanner.cappedGoal(goal))"

        Judge this goal: is it something a shop can fulfill, and does it name one specific \
        product or a set of complementary things?
        """
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

/// The triage instructions: the shared Crumb persona + how to make the two judgments. Deliberately
/// tiny — the whole point of the seam is a sub-second call.
struct TriageInstructions: DynamicInstructions {
    var body: some DynamicInstructions {
        CrumbPersona(recipient: nil)
        Instructions(Self.guide)
    }

    /// The judgment guidance. Pure — unit-tested.
    static let guide = """
        You judge a person's shopping goal — you do not plan or decompose it.

        isShoppable: true when the goal is something a shop can fulfill. false for a question, \
        nonsense, or a non-shopping request (weather, math, chit-chat).

        isSingleItem: true ONLY when the goal names ONE specific product to buy — even when the \
        product's own name contains a word like "kit" or "set" (a sourdough starter kit, a chess \
        set, a first-aid kit are each ONE product). false when fulfilling the goal genuinely \
        needs several complementary things: outfitting or refreshing a space ("dorm room \
        refresh", "set up my pour-over corner"), preparing for an activity or trip, or a \
        "gear" / "equipment" / "supplies" goal for a pursuit ("lacrosse gear", "ski equipment").
        """
}

/// The structured output of a triage call: the two booleans, nothing else — guided generation
/// keeps it a judgment, never a plan.
@Generable
struct GoalJudgmentDraft {
    @Guide(description: "true if this is a shopping goal a shop can fulfill; false for a question, nonsense, or a non-shopping request.")
    var isShoppable: Bool

    @Guide(description: "true ONLY if the goal names ONE specific product to buy (a product whose name contains 'kit' or 'set' — a sourdough starter kit — is still ONE product). false if fulfilling it needs several complementary things: outfitting a space or activity ('dorm room refresh'), or a 'gear'/'equipment'/'supplies' goal ('lacrosse gear').")
    var isSingleItem: Bool
}
