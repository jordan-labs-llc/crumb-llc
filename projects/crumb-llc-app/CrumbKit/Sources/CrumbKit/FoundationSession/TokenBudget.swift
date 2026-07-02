import Foundation
import FoundationModels

/// A shim that lets the generic seam code (which only sees `some LanguageModel`) read the concrete
/// model's real context window. The `LanguageModel` protocol itself does **not** expose the window;
/// only the concrete `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` do, via their
/// `contextSize` property (iOS 27 FoundationModels). Conforming both to one protocol lets the
/// curator/planner obtain a ``TokenBudget`` from whichever tier proved available, without threading
/// an extra parameter through the (already wide) ranking call chain.
public protocol ContextWindowProviding {
    /// The model's usable context window, in tokens.
    var contextWindow: Int { get }
}

extension SystemLanguageModel: ContextWindowProviding {
    public var contextWindow: Int { contextSize }
}

// Gated to match ``AppleFoundationCurator``/``AppleFoundationMissionPlanner``: the PCC tier — and any
// reference to `PrivateCloudComputeLanguageModel` — is compiled in only when the entitlement is
// provisioned (`CRUMB_PCC_ENABLED`). The curator's PCC branch, which is the only caller of
// `TokenBudget(model: pcc)`, lives behind the same flag, so nothing needs this conformance otherwise.
#if CRUMB_PCC_ENABLED
extension PrivateCloudComputeLanguageModel: ContextWindowProviding {
    public var contextWindow: Int { contextSize }
}
#endif

/// A queried, principled token budget for the on-device / Private Cloud Compute Foundation Models
/// sessions (#37). Replaces the old hardcoded 4096-token assumption: the window is read from the
/// live model (`SystemLanguageModel.contextSize` — 8192 on newer hardware, 4096 on older), and the
/// curator's tournament caps and every seam's response bound are *derived* from it rather than
/// hand-tuned to a fixed ceiling.
///
/// The derivations are calibrated so that at the historical **4096-token baseline** they reproduce
/// the exact constants the seams were hand-tuned to (deck 25 / chunk 6 / advance 2 / rank-response
/// 512 / voice-response 200 / planner-response 1024). On a larger window they scale up — capped —
/// so ranking uses larger chunks (fewer model calls) and each generation gets more room, while a
/// small-window device keeps today's proven behavior. Pure and `Sendable` — the unit-tested core.
public struct TokenBudget: Sendable, Equatable {

    /// The window assumed when a real `contextSize` can't be read (model not ready / unavailable).
    /// Documented fallback — the only place the historical 4096 constant survives.
    public static let fallbackContextWindow = 4096

    /// The window the seam tuning was originally calibrated against. At this window every derived
    /// cap equals its historical hand-tuned constant, so behavior is unchanged on a 4096 device.
    public static let baselineContextWindow = 4096

    /// The model's usable context window, in tokens.
    public let contextWindow: Int

    /// Builds a budget from an explicit window, flooring at ``fallbackContextWindow`` so a not-ready
    /// model reporting 0 (or an absurdly small value) never shrinks the caps below today's baseline.
    public init(contextWindow: Int) {
        self.contextWindow = max(Self.fallbackContextWindow, contextWindow)
    }

    /// Reads the queried window off whichever concrete model tier proved available.
    public init(model: some ContextWindowProviding) {
        self.init(contextWindow: model.contextWindow)
    }

    /// The window as a multiple of the calibration baseline (≥ 1) — the factor the caps grow by.
    private var scale: Double { Double(contextWindow) / Double(Self.baselineContextWindow) }

    /// Scales a baseline value by the window ratio, never below the baseline and never above `cap`.
    /// At the 4096 baseline this returns `base` exactly.
    private func scaled(_ base: Int, cap: Int) -> Int {
        min(cap, max(base, Int((Double(base) * scale).rounded())))
    }

    // MARK: Curator tournament caps

    /// How many candidates the model ranks at all (the rest keep deterministic order via the
    /// reconciliation tail). 25 at baseline; a larger window considers a bigger deck.
    public var rankDeckCap: Int { scaled(25, cap: 60) }

    /// The largest set sent to the model in one ranking call. 6 at baseline; a larger window ranks
    /// bigger chunks — so a 25-card deck needs fewer tournament calls (the core #37 win).
    public var rankChunkSize: Int { scaled(6, cap: 12) }

    /// How many of each ranked chunk advance a tournament round. A convergence guard (must stay
    /// strictly below ``rankChunkSize``), independent of the window — fixed at 2.
    public var rankAdvancePerChunk: Int { 2 }

    // MARK: Response bounds (declared on each seam's session Profile)

    /// Ranking response cap — enough for an ID list, bounded so a runaway can't overflow. 512 at baseline.
    public var rankMaxResponseTokens: Int { scaled(512, cap: 1024) }

    /// Per-card voice response cap — a two-sentence rationale. 200 at baseline.
    public var voiceMaxResponseTokens: Int { scaled(200, cap: 400) }

    /// Planner response cap — a `MissionDraft` plan; bounds the PR #12 overflow class. 1024 at baseline.
    public var plannerMaxResponseTokens: Int { scaled(1024, cap: 2048) }
}
