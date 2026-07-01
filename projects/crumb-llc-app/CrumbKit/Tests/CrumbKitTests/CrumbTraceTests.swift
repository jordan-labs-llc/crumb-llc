import Testing
import Foundation
@testable import CrumbKit

/// Guards the *shape* of a pipeline trace line and the tier labels it embeds. The formatting is a
/// pure function on purpose (``CrumbTrace/line(stage:elapsedMillis:summary:)``), so a change to how a
/// trace reads is a deliberate, reviewable edit here rather than silent log drift — and so the
/// measurement can be asserted without capturing the os.Logger stream.
@Suite("CrumbTrace")
struct CrumbTraceTests {

    @Test("A trace line is `stage <ms>ms <summary>`")
    func lineFormat() {
        let line = CrumbTrace.line(stage: "gather", elapsedMillis: 42, summary: "queries=3 candidates=12 agent=true")
        #expect(line == "gather 42ms queries=3 candidates=12 agent=true")
    }

    @Test("Duration → whole milliseconds, floored")
    func millisFloors() {
        #expect(CrumbTrace.millis(.milliseconds(0)) == 0)
        #expect(CrumbTrace.millis(.milliseconds(1500)) == 1500)
        #expect(CrumbTrace.millis(.seconds(2)) == 2000)
        #expect(CrumbTrace.millis(.microseconds(900)) == 0)   // sub-millisecond floors to 0
        #expect(CrumbTrace.millis(.microseconds(1900)) == 1)  // 1.9ms floors to 1
    }

    @Test("Tier labels are compact and encode the fallback reason")
    func tierLabels() {
        #expect(PlannerTier.privateCloud.traceLabel == "pcc")
        #expect(PlannerTier.onDevice.traceLabel == "on-device")
        #expect(PlannerTier.ruleBased(nil).traceLabel == "rule")
        #expect(PlannerTier.ruleBased(.offlineOrError).traceLabel == "rule:offline-or-error")
        #expect(PlannerTier.ruleBased(.appleIntelligenceNotEnabled).traceLabel == "rule:ai-off")

        #expect(CuratorTier.onDevice.traceLabel == "on-device")
        #expect(CuratorTier.ruleBased(nil).traceLabel == "rule")
        #expect(CuratorTier.ruleBased(.modelNotReady).traceLabel == "rule:not-ready")
    }
}
