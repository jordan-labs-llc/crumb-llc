import Foundation
import SwiftData

/// Persists the user's recently typed shopping goals, so the composer can offer them as
/// quick-tap chips ("pick up where you left off").
///
/// A small, deliberately separate seam from ``TasteStore`` — the same injection pattern
/// (SwiftData in the app, an in-memory double in tests). It keeps a short, **deduped,
/// most-recent-first** list capped at ``RecentMissionsStore/cap``; re-adding an existing goal
/// just moves it to the front.
///
/// `@MainActor` because the SwiftData implementation reads/writes the container's
/// `mainContext`, and ``AppModel`` (the only caller) is already `@MainActor`.
@MainActor
public protocol RecentMissionsStore {
    /// The recent goals, most-recent-first (already deduped and capped).
    func loadRecents() -> [String]

    /// Records `goal` as the most recent, moving an existing match to the front and trimming
    /// the list to ``cap``. A blank goal is ignored.
    func addRecent(_ goal: String)
}

public extension RecentMissionsStore {
    /// How many recent goals to keep — a readable handful of chips, no more.
    static var cap: Int { 6 }
}

/// Normalizes + folds a new goal into a recents list: trims it, drops it if blank, removes any
/// case-insensitive duplicate, inserts it at the front, and caps the length. Pure and shared by
/// both store implementations (and the unit-tested guarantee behind them).
@MainActor
func mergedRecents(_ goal: String, into existing: [String], cap: Int) -> [String] {
    let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Array(existing.prefix(cap)) }
    var out = existing.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
    out.insert(trimmed, at: 0)
    return Array(out.prefix(cap))
}

/// The SwiftData-backed ``RecentMissionsStore`` used by the app. One row per goal, ordered by
/// `createdAt`; adding upserts the row to the front and prunes beyond the cap.
@MainActor
public final class SwiftDataRecentMissionsStore: RecentMissionsStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    /// Builds a store over its own container. `inMemory` keeps everything in RAM — the path
    /// tests use to round-trip the real SwiftData stack without touching disk.
    public convenience init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(for: RecentMissionRecord.self, configurations: configuration)
        self.init(container: container)
    }

    public func loadRecents() -> [String] {
        records().map(\.goal)
    }

    public func addRecent(_ goal: String) {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var rows = records()
        // Drop any existing case-insensitive match so re-adding moves it to the front.
        for row in rows where row.goal.caseInsensitiveCompare(trimmed) == .orderedSame {
            context.delete(row)
        }
        rows.removeAll { $0.goal.caseInsensitiveCompare(trimmed) == .orderedSame }

        context.insert(RecentMissionRecord(goal: trimmed))
        // Prune anything past the cap (rows are newest-first; keep the first cap-1, since we
        // just inserted a new newest).
        for stale in rows.dropFirst(Self.cap - 1) {
            context.delete(stale)
        }
        // Best-effort: a failed recents save must never crash the app mid-plan.
        try? context.save()
    }

    /// All recent rows, newest-first.
    private func records() -> [RecentMissionRecord] {
        let descriptor = FetchDescriptor<RecentMissionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}

/// The persisted shape of one recent goal. Kept distinct from the plain `String` the app uses
/// so the schema can grow (e.g. carry the resolved mission) without churning callers.
@Model
public final class RecentMissionRecord {
    public var goal: String
    public var createdAt: Date

    public init(goal: String, createdAt: Date = .init()) {
        self.goal = goal
        self.createdAt = createdAt
    }
}

/// A throwaway in-memory ``RecentMissionsStore`` for tests and the mock scaffold: no SwiftData,
/// no disk. Seed it with goals to simulate a returning user with history.
@MainActor
public final class InMemoryRecentMissionsStore: RecentMissionsStore {
    private var goals: [String]

    public init(_ seed: [String] = []) {
        self.goals = Array(seed.prefix(Self.cap))
    }

    public func loadRecents() -> [String] { goals }

    public func addRecent(_ goal: String) {
        goals = mergedRecents(goal, into: goals, cap: Self.cap)
    }
}
