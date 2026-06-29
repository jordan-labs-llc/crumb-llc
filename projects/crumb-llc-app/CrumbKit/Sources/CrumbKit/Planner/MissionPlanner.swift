import Foundation

/// The mission-planning seam: turns a free-text shopping goal ("set up my pour-over corner")
/// into a structured, **searchable** ``ShoppingTask`` — a title/subtitle, a curator note, an
/// ordered parts list, and one catalog query per part.
///
/// This is the input twin of ``CuratorEngine``/``TasteExtractor``: the deterministic
/// ``RuleBasedMissionPlanner`` is the offline default, and ``AppleFoundationMissionPlanner``
/// is the on-device/server-backed planner that actually *decomposes* a goal. Both report the
/// ``PlannerTier`` they ran on, so the UI can be honest when it wanted the AI planner but had
/// to fall back to the deterministic one.
///
/// A goal that isn't something Crumb can shop for (a question, nonsense, or empty) comes back
/// as a non-shoppable ``PlannedMission`` carrying a short, friendly ``PlannedMission/decline``
/// message instead of a task — so the composer can answer gracefully rather than route into an
/// empty plan.
public protocol MissionPlanner: Sendable {
    /// Decomposes `goal` into a mission, personalized by `profile`. Never throws: an
    /// unusable model tier degrades to the deterministic planner, and a non-shoppable goal
    /// returns a ``PlannedMission`` with `task == nil` and a `decline` message.
    func plan(goal: String, profile: TasteProfile) async -> PlannedMission
}

/// The result of a planning pass: either a decomposed, searchable ``ShoppingTask`` or — when
/// the goal isn't shoppable — a short `decline` message, plus the ``PlannerTier`` that produced
/// it so the UI can surface an honest fallback note.
public struct PlannedMission: Sendable, Equatable {
    /// The decomposed mission, ready to hand to `loadCandidates`. `nil` when the goal isn't
    /// something Crumb can shop for (see `decline`).
    public let task: ShoppingTask?

    /// Which planner tier produced this (drives the honest "planner unavailable" note,
    /// exactly like ``CuratorTier``).
    public let tier: PlannerTier

    /// A short, user-facing sentence shown when `task == nil` — e.g. "I shop for things —
    /// try a goal like 'set up my pour-over corner'." `nil` when a task was produced.
    public let decline: String?

    public init(task: ShoppingTask?, tier: PlannerTier, decline: String? = nil) {
        self.task = task
        self.tier = tier
        self.decline = decline
    }

    /// `true` when the goal decomposed into a searchable mission.
    public var isShoppable: Bool { task != nil }
}

/// Which planner produced a mission. Mirrors ``CuratorTier`` so the planning path tells the
/// same honest story as curation: `ruleBased(nil)` is the *chosen* offline default (the UI
/// stays quiet), while `ruleBased(reason)` means an AI planner was wanted but unavailable.
public enum PlannerTier: Sendable, Equatable {
    /// Apple's server-tier model (`PrivateCloudComputeLanguageModel`, OS 27+).
    case privateCloud
    /// The on-device model (`SystemLanguageModel.default`) — offline, lower quality.
    case onDevice
    /// The deterministic ``RuleBasedMissionPlanner``. `reason == nil` means it was the chosen
    /// default (the mock scaffold / sim) and the UI should stay quiet; a non-`nil` reason
    /// means an AI tier was *wanted* but unavailable, which the UI surfaces explicitly.
    case ruleBased(Fallback?)

    /// Why an AI planner tier could not be used, so the UI can phrase an honest note.
    public enum Fallback: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case quotaExhausted
        case offlineOrError
    }
}

public extension PlannerTier {
    /// A short, user-facing note when an AI planner was wanted but unavailable, else `nil`.
    /// Kept in CrumbKit so the voice copy lives next to the seam, not in the views.
    var fallbackNote: String? {
        guard case let .ruleBased(reason?) = self else { return nil }
        switch reason {
        case .deviceNotEligible:
            return "Smart planning needs an Apple Intelligence device — I built a simple "
                + "plan from your words."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to let me break goals down in "
                + "detail. For now, here's a simple plan."
        case .modelNotReady:
            return "My planner model is still downloading — here's a simple plan from your "
                + "words until it's ready."
        case .quotaExhausted:
            return "You've used up this period's private-cloud planning — here's a simple "
                + "plan for now."
        case .offlineOrError:
            return "Couldn't reach the planner just now — I built a simple plan from your "
                + "words."
        }
    }
}
