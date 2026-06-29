import Foundation
import SwiftData

/// Persists the user's past missions — each a ``HistoryEntry`` pairing the plan they ran with the
/// kit they built — so the app has a durable, offline-viewable record (the agent loop's memory).
///
/// A third persistence seam alongside ``TasteStore`` and ``RecentMissionsStore``, with the same
/// injection shape: SwiftData in the app, an in-memory double in tests. Entries are kept
/// **most-recent-first** and capped at ``HistoryStore/cap`` with oldest-first eviction, so the
/// store never grows unbounded — mirroring the dedupe/cap discipline of ``RecentMissionsStore``.
///
/// Distinct from ``RecentMissionsStore`` on purpose: recents are throwaway goal *strings* for fast
/// re-prompting; history is the richer, persisted *outcome* of a session. Two stores, two roles.
///
/// `@MainActor` because the SwiftData implementation reads/writes the container's `mainContext`,
/// and ``AppModel`` (the only caller) is already `@MainActor`.
@MainActor
public protocol HistoryStore {
    /// All saved entries, most-recent-first (already capped).
    func loadEntries() -> [HistoryEntry]

    /// Inserts `entry`, or replaces the existing row with the same id (the same-session update
    /// path). Evicts the oldest beyond ``cap`` so history stays bounded.
    func save(_ entry: HistoryEntry)

    /// Flips an entry's outcome flag (the "handed off to checkout" update). No-op if the id is gone.
    func setHandedOff(_ id: String, _ value: Bool)

    /// Deletes a single entry (swipe / menu).
    func delete(id: String)

    /// Clears the whole history ("Clear history").
    func clear()
}

public extension HistoryStore {
    /// How many entries to keep before evicting the oldest — a generous but bounded record.
    static var cap: Int { 50 }
}

/// Normalizes + folds an entry into a history list: drops any row with the same id (the upsert),
/// inserts the new one, re-sorts most-recent-first, and caps the length (evicting the oldest).
/// Pure — it backs ``InMemoryHistoryStore`` and is the unit-tested statement of the policy
/// ``SwiftDataHistoryStore`` enforces directly against the store (upsert via `record(id:)`, sort +
/// `evictBeyondCap`). The two are intentionally kept in lockstep with shared tests.
@MainActor
func mergedEntries(_ entry: HistoryEntry, into existing: [HistoryEntry], cap: Int) -> [HistoryEntry] {
    var out = existing.filter { $0.id != entry.id }
    out.append(entry)
    out.sort { $0.createdAt > $1.createdAt }
    return Array(out.prefix(cap))
}

/// The SwiftData-backed ``HistoryStore`` used by the app. One row per session; saving upserts by
/// id and prunes beyond the cap. The kit is stored as a JSON blob on the row (lean — no child
/// relationship), so the schema mirrors ``TasteProfileRecord``'s single-row simplicity.
@MainActor
public final class SwiftDataHistoryStore: HistoryStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    /// Builds a store over its own container. `inMemory` keeps everything in RAM — the path tests
    /// use to round-trip the real SwiftData stack without touching disk.
    public convenience init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(for: HistoryEntryRecord.self, configurations: configuration)
        self.init(container: container)
    }

    public func loadEntries() -> [HistoryEntry] {
        records().prefix(Self.cap).map(\.entry)
    }

    public func save(_ entry: HistoryEntry) {
        if let row = record(id: entry.id) {
            row.apply(entry)
        } else {
            context.insert(HistoryEntryRecord(entry))
        }
        evictBeyondCap()
        // Best-effort: a failed history save must never crash the app mid-checkout.
        try? context.save()
    }

    public func setHandedOff(_ id: String, _ value: Bool) {
        guard let row = record(id: id) else { return }
        row.handedOff = value
        try? context.save()
    }

    public func delete(id: String) {
        guard let row = record(id: id) else { return }
        context.delete(row)
        try? context.save()
    }

    public func clear() {
        for row in records() { context.delete(row) }
        try? context.save()
    }

    /// All rows, newest-first.
    private func records() -> [HistoryEntryRecord] {
        let descriptor = FetchDescriptor<HistoryEntryRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The single row with `entryID`, if present.
    private func record(id: String) -> HistoryEntryRecord? {
        var descriptor = FetchDescriptor<HistoryEntryRecord>(
            predicate: #Predicate { $0.entryID == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Deletes anything past the cap (rows are newest-first; keep the first `cap`).
    private func evictBeyondCap() {
        for stale in records().dropFirst(Self.cap) {
            context.delete(stale)
        }
    }
}

/// The persisted shape of a ``HistoryEntry``. The kit is stored as a JSON-encoded blob
/// (`itemsData`) rather than a SwiftData relationship — lean, and it keeps the snapshot a single
/// self-contained receipt. `accentHex` is stored as `Int` (SwiftData-friendly; the value fits).
@Model
public final class HistoryEntryRecord {
    @Attribute(.unique) public var entryID: String
    public var goal: String
    public var title: String
    public var subtitle: String
    public var plan: [String]
    public var searchQueries: [String]
    public var curatorNote: String
    public var accentHex: Int
    public var recapTag: String
    public var recapLine: String
    public var itemsData: Data
    public var handedOff: Bool
    public var createdAt: Date

    public init(_ entry: HistoryEntry) {
        self.entryID = entry.id
        self.goal = entry.goal
        self.title = entry.title
        self.subtitle = entry.subtitle
        self.plan = entry.plan
        self.searchQueries = entry.searchQueries
        self.curatorNote = entry.curatorNote
        self.accentHex = Int(entry.accentHex)
        self.recapTag = entry.recapTag
        self.recapLine = entry.recapLine
        self.itemsData = Self.encode(entry.items)
        self.handedOff = entry.handedOff
        self.createdAt = entry.createdAt
    }

    /// The domain value this row represents.
    public var entry: HistoryEntry {
        HistoryEntry(
            id: entryID,
            goal: goal,
            title: title,
            subtitle: subtitle,
            plan: plan,
            searchQueries: searchQueries,
            curatorNote: curatorNote,
            accentHex: UInt32(truncatingIfNeeded: accentHex),
            recapTag: recapTag,
            recapLine: recapLine,
            items: Self.decode(itemsData),
            handedOff: handedOff,
            createdAt: createdAt
        )
    }

    /// Overwrites this row's fields with `entry` (the upsert path). Keeps `entryID`/`createdAt`
    /// from the new value, which for a same-session update carry the original's preserved values.
    public func apply(_ entry: HistoryEntry) {
        goal = entry.goal
        title = entry.title
        subtitle = entry.subtitle
        plan = entry.plan
        searchQueries = entry.searchQueries
        curatorNote = entry.curatorNote
        accentHex = Int(entry.accentHex)
        recapTag = entry.recapTag
        recapLine = entry.recapLine
        itemsData = Self.encode(entry.items)
        handedOff = entry.handedOff
        createdAt = entry.createdAt
    }

    private static func encode(_ items: [HistoryItem]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data()
    }

    private static func decode(_ data: Data) -> [HistoryItem] {
        (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }
}

/// A throwaway in-memory ``HistoryStore`` for tests and the screenshot scaffold: no SwiftData, no
/// disk. Seed it with entries to simulate a returning user with a rich history (or leave it empty
/// for the first-run timeline).
@MainActor
public final class InMemoryHistoryStore: HistoryStore {
    private var entries: [HistoryEntry]

    public init(_ seed: [HistoryEntry] = []) {
        self.entries = Array(seed.sorted { $0.createdAt > $1.createdAt }.prefix(Self.cap))
    }

    public func loadEntries() -> [HistoryEntry] { entries }

    public func save(_ entry: HistoryEntry) {
        entries = mergedEntries(entry, into: entries, cap: Self.cap)
    }

    public func setHandedOff(_ id: String, _ value: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = entries[index].withHandedOff(value)
    }

    public func delete(id: String) {
        entries.removeAll { $0.id == id }
    }

    public func clear() {
        entries.removeAll()
    }
}
