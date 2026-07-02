import Foundation

/// The latency safety net around the agentic gather's single, unbounded model turn (#54).
///
/// The agentic loop has no time bound and no zero-progress detection: when the on-device model
/// misbehaves (observed: it trips its own safety guardrails mid-turn on the Xcode 27 beta) the whole
/// gather stalls 40–60s before the deterministic floor — which produces results in ~2s — gets its
/// turn, because today the floor runs only *after* the model turn ends. This wraps the turn in two
/// independent timers plus a single-flight floor:
///
/// - **Watchdog** (`watchdogSeconds`): fires only if the pool is still empty at the deadline →
///   launch the deterministic floor *now*, in parallel with the still-running turn, so the UI
///   un-sticks at floor latency. No-ops (zero cost) the moment the model produced any pick first.
/// - **Turn deadline** (`deadlineSeconds`): abandons a runaway turn (cancel + move on) so a turn
///   that never throws still can't hang the gather.
/// - **FloorLatch**: the floor can now be wanted from three places (watchdog, a pool-below-floor
///   union, an empty-pool fallback); it MUST run at most once per gather. The latch memoizes the
///   floor `Task` and hands its value to every caller.
///
/// Deliberately model-free and network-free: it takes the turn, the pool snapshot, and the floor as
/// closures, so the entire timing / at-most-once behavior is unit-testable in CI with fake async
/// closures and millisecond timeouts. The model-touching orchestrator supplies the real closures.
struct GatherSafetyNet {
    /// How long time-to-first-pick may sit at zero before the floor is launched alongside the turn.
    /// Floor search P50 is 1–3s and a cooperative model's first tool call lands well under this
    /// (observed ~3s), so the watchdog never preempts a healthy loop but bounds worst-case
    /// time-to-first-pick at ~`watchdogSeconds` + floor latency.
    let watchdogSeconds: Double
    /// How long the model turn may run before it's abandoned and the gather proceeds with whatever
    /// the pool holds — caps the observed 44–66s runaway well above healthy loop lengths.
    let deadlineSeconds: Double

    /// Fired (with the pool count, 0) when the watchdog launches the floor. Injected so the
    /// orchestrator can trace it and tests can assert it, keeping this type free of tracing deps.
    var onWatchdogFired: @Sendable (Int) -> Void = { _ in }
    /// Fired (with the pool count at cancellation) when the turn deadline abandons the turn.
    var onDeadlineFired: @Sendable (Int) -> Void = { _ in }

    /// How the model turn ended — drives the `usedAgent` verdict.
    private enum TurnEnd: Sendable { case completed, threw, deadline }

    /// Runs `turn` under the watchdog + deadline, launching `floorGather` at most once whenever the
    /// floor is wanted, and converges on the pool. Returns the gathered pool, or `nil` only when the
    /// agent contributed nothing AND the floor itself reported a total outage (the seam's `nil`
    /// contract). `floor` is the minimum pool size below which the floor tops the agent pool up.
    func run(
        floor: Int,
        turn: @escaping @Sendable () async throws -> Void,
        poolSnapshot: @escaping @Sendable () async -> [Product],
        floorGather: @escaping @Sendable () async -> GatheredCandidates?
    ) async -> GatheredCandidates? {
        let latch = FloorLatch()

        // Watchdog — launch the floor in parallel iff nothing has streamed by `watchdogSeconds`.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(watchdogSeconds))
            guard !Task.isCancelled, await poolSnapshot().isEmpty else { return }
            onWatchdogFired(0)
            _ = await latch.run(floorGather)
        }

        // Race the turn against the deadline. The turn runs UNSTRUCTURED so a runaway turn that
        // ignores cooperative cancellation can be abandoned without blocking this function on it —
        // we never `await turnTask.value`, we only observe whichever signal lands first.
        let (signals, continuation) = AsyncStream.makeStream(of: TurnEnd.self)
        let turnTask = Task {
            let end: TurnEnd
            do { try await turn(); end = .completed } catch { end = .threw }
            continuation.yield(end)
        }
        let deadlineTask = Task {
            do { try await Task.sleep(for: .seconds(deadlineSeconds)); continuation.yield(.deadline) }
            catch { /* cancelled because the turn finished first — no deadline signal */ }
        }

        var end: TurnEnd = .completed
        for await signal in signals { end = signal; break }
        deadlineTask.cancel()
        if end == .deadline { turnTask.cancel() }   // abandon the runaway turn (cooperative)
        watchdog.cancel()

        // Only the watchdog can have run the floor before convergence, so the latch state IS the
        // "watchdog fired" signal.
        let watchdogFired = await latch.hasRun
        if end == .deadline { onDeadlineFired(await poolSnapshot().count) }

        // Converge: the agent pool, topped up to `floor` when short, the full floor when empty.
        // Every floor want funnels through the same latch, so it runs at most once whoever asks.
        var pool = await poolSnapshot()
        if pool.count < floor, let topUp = await latch.run(floorGather) {
            pool = Self.mergeDedup(pool, topUp.products)
        }
        if pool.isEmpty {
            return await latch.run(floorGather)   // nil only if the floor is a true outage
        }
        // The agent earns `usedAgent` only if it genuinely drove the gather: a clean turn with no
        // watchdog rescue. A throw, a deadline abandon, or a watchdog launch all read as floor-led.
        let usedAgent = end == .completed && !watchdogFired
        return GatheredCandidates(products: pool, usedAgent: usedAgent)
    }

    /// Merges two pools, `primary` order first then any new-by-id from `secondary`. Pure. (Mirrors
    /// the orchestrator's own merge; kept here so the net is self-contained and independently tested.)
    static func mergeDedup(_ primary: [Product], _ secondary: [Product]) -> [Product] {
        var seen = Set(primary.map(\.id))
        var out = primary
        for product in secondary where seen.insert(product.id).inserted { out.append(product) }
        return out
    }
}

/// Runs the floor gather at most once per ``GatherSafetyNet/run(floor:turn:poolSnapshot:floorGather:)``,
/// whoever asks first; later callers await the same `Task`'s value. An actor so the watchdog, the
/// union, and the fallback can race for it safely.
private actor FloorLatch {
    private var inFlight: Task<GatheredCandidates?, Never>?

    func run(_ gather: @escaping @Sendable () async -> GatheredCandidates?) async -> GatheredCandidates? {
        if let inFlight { return await inFlight.value }
        let task = Task { await gather() }
        inFlight = task
        return await task.value
    }

    /// `true` once the floor has been launched — the net reads this as "did the watchdog fire?".
    var hasRun: Bool { inFlight != nil }
}
