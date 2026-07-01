import Foundation
import os

/// Lightweight, dependency-free tracing for the curation pipeline (**plan → gather → gate → curate**).
///
/// The pipeline used to be a black box: each seam computed its own candidate / keep-drop counts and
/// then discarded them, and nothing timed a stage, so a slow or off-target run left nothing to read
/// after the fact. `CrumbTrace` is the measurement seam — one line per stage carrying the stage's
/// elapsed wall time and the input→output counts it decided (plus the degrade *tier* when a model
/// step fell back to the deterministic floor).
///
/// It logs at **`.info`**: these are happy-path measurements, not errors (the seams already log
/// `.error` on the degrade/throw paths — see `AppleFoundation*`). Formatting is a **pure** function
/// (``line(stage:elapsedMillis:summary:)``) so the exact shape can be asserted in a unit test without
/// capturing the log stream; ``emit(stage:elapsedMillis:summary:)`` is the only side effect (an
/// `os.Logger` write under the shared `llc.crumb.CrumbKit` subsystem, category `Trace`).
public enum CrumbTrace {
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "Trace")

    /// Formats one trace line: `"<stage> <elapsed>ms <summary>"`. Pure — the unit-tested shape, so a
    /// change to the line format is a deliberate, reviewable edit rather than log drift.
    public static func line(stage: String, elapsedMillis: Int, summary: String) -> String {
        "\(stage) \(elapsedMillis)ms \(summary)"
    }

    /// Emits a stage trace at `.info`. The message is `.public` because it carries only counts,
    /// timings, and tier labels — never user text, product data, or PII.
    public static func emit(stage: String, elapsedMillis: Int, summary: String) {
        log.info("\(line(stage: stage, elapsedMillis: elapsedMillis, summary: summary), privacy: .public)")
    }

    /// Times `body`, emits a stage trace built from its result via `summarize`, and returns the
    /// result. The single entry point call sites use, so the timing and the emit can't drift apart
    /// (you can't measure one thing and log another). Non-throwing on purpose: the pipeline stages
    /// self-degrade rather than throw, and a trace must never change control flow.
    @discardableResult
    public static func measure<T>(
        _ stage: String,
        summarize: (T) -> String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async -> T
    ) async -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await body()
        emit(stage: stage, elapsedMillis: Self.millis(start.duration(to: clock.now)), summary: summarize(result))
        return result
    }

    /// Whole-milliseconds of a `Duration` (floored), for a compact human-readable trace. `components`
    /// yields `(seconds, attoseconds)`; there are 1e15 attoseconds per millisecond.
    static func millis(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

/// A compact, stable token for a planner tier — `pcc` / `on-device` / `rule` (with the fallback
/// reason appended when the deterministic floor was reached because a model was expected).
public extension PlannerTier {
    var traceLabel: String {
        switch self {
        case .privateCloud: return "pcc"
        case .onDevice: return "on-device"
        case .ruleBased(nil): return "rule"
        case .ruleBased(let reason?): return "rule:\(reason.traceToken)"
        }
    }
}

/// A compact, stable token for a curator tier — mirrors ``PlannerTier/traceLabel``.
public extension CuratorTier {
    var traceLabel: String {
        switch self {
        case .privateCloud: return "pcc"
        case .onDevice: return "on-device"
        case .ruleBased(nil): return "rule"
        case .ruleBased(let reason?): return "rule:\(reason.traceToken)"
        }
    }
}

private extension PlannerTier.Fallback {
    var traceToken: String {
        switch self {
        case .deviceNotEligible: return "ineligible"
        case .appleIntelligenceNotEnabled: return "ai-off"
        case .modelNotReady: return "not-ready"
        case .quotaExhausted: return "quota"
        case .offlineOrError: return "offline-or-error"
        }
    }
}

private extension CuratorTier.Fallback {
    var traceToken: String {
        switch self {
        case .deviceNotEligible: return "ineligible"
        case .appleIntelligenceNotEnabled: return "ai-off"
        case .modelNotReady: return "not-ready"
        case .quotaExhausted: return "quota"
        case .offlineOrError: return "offline-or-error"
        }
    }
}
