import Testing
import Foundation
@testable import CrumbKit

/// The CI-safe timing/at-most-once guarantees behind the agentic-gather safety net (#54). No model,
/// no network — fake async closures with millisecond timeouts stand in for the model turn and the
/// deterministic floor, so the watchdog / turn-deadline / single-flight-latch behavior is exercised
/// deterministically. Timing assertions use generous ceilings, never exact durations.
@Suite("GatherSafetyNet (#54)")
struct GatherSafetyNetTests {

    /// A fake pool + floor: the turn adds "agent" picks, the floor adds its own picks and counts its
    /// runs so a test can prove the floor ran at most once (single-flight).
    private actor Fake {
        private(set) var pool: [Product] = []
        private(set) var floorRuns = 0
        let floorProducts: [Product]
        let floorDelay: Duration

        init(floorProducts: [Product], floorDelay: Duration = .milliseconds(10)) {
            self.floorProducts = floorProducts
            self.floorDelay = floorDelay
        }

        func addAgent(_ products: [Product]) { pool = GatherSafetyNet.mergeDedup(pool, products) }
        func snapshot() -> [Product] { pool }

        func runFloor() async -> GatheredCandidates? {
            floorRuns += 1
            try? await Task.sleep(for: floorDelay)
            pool = GatherSafetyNet.mergeDedup(pool, floorProducts)
            return floorProducts.isEmpty ? nil : GatheredCandidates(products: floorProducts, usedAgent: false)
        }
    }

    private var agentPicks: [Product] { Array(SeedData.coffeeProducts.prefix(2)) }
    private var floorPicks: [Product] { Array(SeedData.hikeProducts.prefix(3)) }

    @Test("A turn that produces picks before the watchdog never runs the floor; usedAgent is true")
    func turnCompletesBeforeWatchdog() async {
        let fake = Fake(floorProducts: floorPicks)
        let net = GatherSafetyNet(watchdogSeconds: 1.0, deadlineSeconds: 5.0)
        let result = await net.run(
            floor: 1,
            turn: { await fake.addAgent(self.agentPicks) },
            poolSnapshot: { await fake.snapshot() },
            floorGather: { await fake.runFloor() }
        )
        #expect(await fake.floorRuns == 0)
        #expect(result?.usedAgent == true)
        #expect(result?.products.count == agentPicks.count)
    }

    @Test("An empty, slow turn trips the watchdog, which runs the floor exactly once")
    func watchdogFiresWhenPoolStaysEmpty() async {
        let fake = Fake(floorProducts: floorPicks)
        let net = GatherSafetyNet(watchdogSeconds: 0.05, deadlineSeconds: 5.0)
        let result = await net.run(
            floor: 1,
            turn: { try? await Task.sleep(for: .milliseconds(300)) },   // empty, ends after watchdog
            poolSnapshot: { await fake.snapshot() },
            floorGather: { await fake.runFloor() }
        )
        #expect(await fake.floorRuns == 1)
        #expect(result?.products.count == floorPicks.count)
        #expect(result?.usedAgent == false)                            // watchdog rescued → floor-led
    }

    @Test("A turn that throws after the watchdog already ran the floor still yields one run, non-nil")
    func throwAfterWatchdogStillOneFloor() async {
        let fake = Fake(floorProducts: floorPicks)
        let net = GatherSafetyNet(watchdogSeconds: 0.05, deadlineSeconds: 5.0)
        let result = await net.run(
            floor: 1,
            turn: { try await Task.sleep(for: .milliseconds(200)); throw CancellationError() },
            poolSnapshot: { await fake.snapshot() },
            floorGather: { await fake.runFloor() }
        )
        #expect(await fake.floorRuns == 1)
        #expect(result != nil)
        #expect(result?.usedAgent == false)
    }

    @Test("A runaway turn is abandoned at the deadline; the gather returns bounded, not on the zombie")
    func deadlineAbandonsRunawayTurn() async {
        let fake = Fake(floorProducts: floorPicks)
        let net = GatherSafetyNet(watchdogSeconds: 5.0, deadlineSeconds: 0.15)   // watchdog won't fire
        let start = ContinuousClock.now
        let result = await net.run(
            floor: 1,
            turn: {
                // A zombie that ignores cooperative cancellation (`try?` swallows it), ~2s of work.
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(50)) }
            },
            poolSnapshot: { await fake.snapshot() },
            floorGather: { await fake.runFloor() }
        )
        let elapsed = ContinuousClock.now - start
        #expect(result?.products.count == floorPicks.count)            // floor fallback (pool empty)
        #expect(result?.usedAgent == false)
        #expect(await fake.floorRuns == 1)
        #expect(elapsed < .seconds(1))                                 // ~deadline+floor, not ~2s
    }

    @Test("Total outage — empty turn and a floor that reports nil — returns nil (contract preserved)")
    func totalOutageReturnsNil() async {
        let fake = Fake(floorProducts: [])                             // floor → nil
        let net = GatherSafetyNet(watchdogSeconds: 0.05, deadlineSeconds: 2.0)
        let result = await net.run(
            floor: 1,
            turn: { try? await Task.sleep(for: .milliseconds(150)) },
            poolSnapshot: { await fake.snapshot() },
            floorGather: { await fake.runFloor() }
        )
        #expect(result == nil)
        #expect(await fake.floorRuns == 1)                             // watchdog + fallback → one run
    }

    @Test("A short agent pool is topped up to the floor via a single floor run; agent still led")
    func unionTopsUpBelowFloor() async {
        let fake = Fake(floorProducts: floorPicks)
        let net = GatherSafetyNet(watchdogSeconds: 5.0, deadlineSeconds: 5.0)   // neither fires
        let result = await net.run(
            floor: 5,
            turn: { await fake.addAgent(self.agentPicks) },            // 2 picks, below floor 5
            poolSnapshot: { await fake.snapshot() },
            floorGather: { await fake.runFloor() }
        )
        #expect(result?.products.count == agentPicks.count + floorPicks.count)   // 2 + 3, disjoint
        #expect(await fake.floorRuns == 1)
        #expect(result?.usedAgent == true)                            // clean turn, no watchdog
    }

    // MARK: CandidateCollector hardening

    @Test("add() after finish() is a full no-op; finish() is idempotent")
    func collectorAddAfterFinishIsNoOp() async {
        let collector = CandidateCollector()
        await collector.add(Array(SeedData.hikeProducts.prefix(2)))
        #expect(await collector.count == 2)

        await collector.finish()
        await collector.add(Array(SeedData.hikeProducts.suffix(3)))   // zombie write — must be ignored
        #expect(await collector.count == 2)
        #expect(await collector.products.count == 2)

        await collector.finish()                                       // idempotent
        #expect(await collector.count == 2)
    }
}
