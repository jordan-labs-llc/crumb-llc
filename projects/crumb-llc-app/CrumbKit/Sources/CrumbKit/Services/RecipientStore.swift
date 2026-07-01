import Foundation
import SwiftData
import os

/// Persists the roster of people you shop *for* — each a ``Recipient`` with their own taste — so
/// gift missions can curate to a saved person across launches.
///
/// The **fourth** persistence seam, alongside ``TasteStore``, ``RecentMissionsStore``, and
/// ``HistoryStore``, with the same injection shape: SwiftData in the app, an in-memory double in
/// tests. Distinct from the others on purpose: a recipient is an *intentional, long-lived* entity,
/// so the roster is added/edited/deleted **by hand** and bounded only by a generous sanity
/// ``RecipientStore/cap`` — there is **no** silent oldest-first eviction (that would quietly drop a
/// person you meant to keep). Entries are kept **most-recently-added-first**.
///
/// `@MainActor` because the SwiftData implementation reads/writes the container's `mainContext`,
/// and ``AppModel`` (the only caller) is already `@MainActor`.
@MainActor
public protocol RecipientStore {
    /// The whole roster, most-recently-added-first.
    func loadRecipients() -> [Recipient]

    /// Inserts `recipient`, or replaces the existing row with the same id (the edit path).
    func save(_ recipient: Recipient)

    /// Removes a person from the roster (the only way the roster shrinks).
    func delete(id: String)
}

public extension RecipientStore {
    /// A generous sanity bound on the roster — high enough that a real user never hits it, so the
    /// only routine way to shrink the roster is a deliberate delete.
    static var cap: Int { 50 }
}

/// Normalizes + folds a recipient into a roster: drops any row with the same id (the upsert),
/// inserts the new one, re-sorts most-recently-added-first, and caps the length. Pure — it backs
/// ``InMemoryRecipientStore`` and is the unit-tested statement of the policy
/// ``SwiftDataRecipientStore`` enforces directly. Unlike ``mergedEntries(_:into:cap:)`` there is no
/// "evict the oldest" intent: the cap only guards against unbounded growth, and the editing UI keeps
/// the roster well under it.
@MainActor
func mergedRecipients(_ recipient: Recipient, into existing: [Recipient], cap: Int) -> [Recipient] {
    var out = existing.filter { $0.id != recipient.id }
    out.append(recipient)
    out.sort { $0.createdAt > $1.createdAt }
    return Array(out.prefix(cap))
}

/// The SwiftData-backed ``RecipientStore`` used by the app. One row per person; saving upserts by
/// id. The taste profile is stored as a JSON blob on the row (lean — no child relationship), and
/// `accentHex` as `Int`, mirroring ``HistoryEntryRecord``.
@MainActor
public final class SwiftDataRecipientStore: RecipientStore {
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "Persistence")
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Best-effort save: a failed roster write must never crash the app mid-edit, but it's logged
    /// so a silent persistence failure can't hide the way the store-collision bug did.
    private func persist() {
        do {
            try context.save()
        } catch {
            Self.log.error("recipient save failed: \(error, privacy: .public)")
        }
    }

    public init(container: ModelContainer) {
        self.container = container
    }

    /// Builds a store over its own container. `inMemory` keeps everything in RAM — the path tests
    /// use to round-trip the real SwiftData stack without touching disk.
    public convenience init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(for: RecipientRecord.self, configurations: configuration)
        self.init(container: container)
    }

    public func loadRecipients() -> [Recipient] {
        records().prefix(Self.cap).map(\.recipient)
    }

    public func save(_ recipient: Recipient) {
        if let row = record(id: recipient.id) {
            row.apply(recipient)
        } else {
            context.insert(RecipientRecord(recipient))
        }
        persist()
    }

    public func delete(id: String) {
        guard let row = record(id: id) else { return }
        context.delete(row)
        persist()
    }

    /// All rows, newest-first.
    private func records() -> [RecipientRecord] {
        let descriptor = FetchDescriptor<RecipientRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The single row with `recipientID`, if present.
    private func record(id: String) -> RecipientRecord? {
        var descriptor = FetchDescriptor<RecipientRecord>(
            predicate: #Predicate { $0.recipientID == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The persisted shape of a ``Recipient``. The taste profile is stored as a JSON-encoded blob
/// (`tasteData`) rather than a SwiftData relationship — lean and self-contained. `accentHex` is
/// stored as `Int` (SwiftData-friendly; the value fits).
@Model
public final class RecipientRecord {
    @Attribute(.unique) public var recipientID: String
    public var name: String
    public var relationship: String?
    public var tasteData: Data
    public var accentHex: Int
    public var createdAt: Date

    public init(_ recipient: Recipient) {
        self.recipientID = recipient.id
        self.name = recipient.name
        self.relationship = recipient.relationship
        self.tasteData = Self.encode(recipient.taste)
        self.accentHex = Int(recipient.accentHex)
        self.createdAt = recipient.createdAt
    }

    /// The domain value this row represents.
    public var recipient: Recipient {
        Recipient(
            id: recipientID,
            name: name,
            relationship: relationship,
            taste: Self.decode(tasteData),
            accentHex: UInt32(truncatingIfNeeded: accentHex),
            createdAt: createdAt
        )
    }

    /// Overwrites this row's mutable fields with `recipient` (the upsert path). Keeps the original
    /// `recipientID` / `createdAt`.
    public func apply(_ recipient: Recipient) {
        name = recipient.name
        relationship = recipient.relationship
        tasteData = Self.encode(recipient.taste)
        accentHex = Int(recipient.accentHex)
    }

    private static func encode(_ taste: TasteProfile) -> Data {
        (try? JSONEncoder().encode(taste)) ?? Data()
    }

    private static func decode(_ data: Data) -> TasteProfile {
        (try? JSONDecoder().decode(TasteProfile.self, from: data))
            ?? TasteProfile(vibe: [], leanings: [], budgetComfort: 0.5, signatureLine: "")
    }
}

/// A throwaway in-memory ``RecipientStore`` for tests and the screenshot scaffold: no SwiftData, no
/// disk. Seed it with people to simulate a returning user with a roster (or leave it empty for the
/// "no people yet" first-run state).
@MainActor
public final class InMemoryRecipientStore: RecipientStore {
    private var recipients: [Recipient]

    public init(_ seed: [Recipient] = []) {
        self.recipients = Array(seed.sorted { $0.createdAt > $1.createdAt }.prefix(Self.cap))
    }

    public func loadRecipients() -> [Recipient] { recipients }

    public func save(_ recipient: Recipient) {
        recipients = mergedRecipients(recipient, into: recipients, cap: Self.cap)
    }

    public func delete(id: String) {
        recipients.removeAll { $0.id == id }
    }
}
