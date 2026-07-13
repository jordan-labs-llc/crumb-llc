import Foundation
import SwiftData
import os

/// One quarantined persisted row. The header remains available so the UI can offer Delete even
/// when the aggregate JSON cannot be decoded safely.
public struct MissionThreadLoadFailure: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let reason: String

    public init(id: String, title: String, reason: String) {
        self.id = id
        self.title = title
        self.reason = reason
    }
}

/// A load never turns a corrupt row into an empty mission or silently omits it.
public struct MissionThreadLoadBatch: Sendable {
    public let threads: [MissionThread]
    public let failures: [MissionThreadLoadFailure]

    public init(threads: [MissionThread], failures: [MissionThreadLoadFailure] = []) {
        self.threads = threads
        self.failures = failures
    }
}

public enum MissionThreadStoreError: Error, Hashable, Sendable {
    case staleRevision(stored: Int, incoming: Int)
    case conflictingRevision(Int)
    case fetchFailed(String)
}

/// Persistence seam for the authoritative mission workspace.
///
/// Saves are synchronous, throwing, and revision ordered. The caller may keep its in-memory thread
/// usable after an error, but must surface that it was not saved and provide a retry.
@MainActor
public protocol MissionThreadStore {
    func load() -> MissionThreadLoadBatch
    func save(_ thread: MissionThread) throws
    func delete(id: String) throws
    func clear() throws
}

public extension MissionThreadStore {
    /// The bounded continuation list. Completed/abandoned missions live in independent History rows.
    static var cap: Int { 12 }
}

/// The SwiftData row intentionally has stable scalar headers plus one versioned aggregate blob.
/// New domain fields evolve inside the document codec instead of churning the database schema.
@Model
public final class MissionThreadRecord {
    @Attribute(.unique) public var threadID: String
    public var revision: Int
    public var title: String
    public var phaseRaw: String
    public var payloadData: Data
    public var createdAt: Date
    public var updatedAt: Date

    public init(_ thread: MissionThread, payloadData: Data) {
        threadID = thread.id
        revision = thread.revision
        title = thread.goal
        phaseRaw = thread.phase.rawValue
        self.payloadData = payloadData
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
    }

    public func apply(_ thread: MissionThread, payloadData: Data) {
        revision = thread.revision
        title = thread.goal
        phaseRaw = thread.phase.rawValue
        self.payloadData = payloadData
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
    }
}

@MainActor
public final class SwiftDataMissionThreadStore: MissionThreadStore {
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "Persistence")
    private let container: ModelContainer
    private let clock: () -> Date
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer, clock: @escaping () -> Date = Date.init) {
        self.container = container
        self.clock = clock
    }

    public convenience init(inMemory: Bool = false, clock: @escaping () -> Date = Date.init) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(for: MissionThreadRecord.self, configurations: configuration)
        self.init(container: container, clock: clock)
    }

    public func load() -> MissionThreadLoadBatch {
        var threads: [MissionThread] = []
        var failures: [MissionThreadLoadFailure] = []
        var recoveredRows = false

        let rows: [MissionThreadRecord]
        do { rows = try records() }
        catch {
            return MissionThreadLoadBatch(threads: [], failures: [MissionThreadLoadFailure(
                id: "mission-thread-store", title: "Saved missions unavailable",
                reason: String(describing: error)
            )])
        }

        for row in rows {
            do {
                let sourceVersion = try MissionThreadCodec.schemaVersion(in: row.payloadData)
                var thread = try MissionThreadCodec.decode(row.payloadData)
                // The scalar id/revision are an ordering and identity guard, not an alternate truth.
                guard thread.id == row.threadID, thread.revision == row.revision else {
                    throw MissionThreadStoreError.conflictingRevision(row.revision)
                }
                if thread.pendingOperation != nil {
                    try thread.recoverAfterInterruption(at: clock())
                    let payload = try MissionThreadCodec.encode(thread)
                    row.apply(thread, payloadData: payload)
                    recoveredRows = true
                }
                if sourceVersion < MissionThreadCodec.currentVersion {
                    row.apply(thread, payloadData: try MissionThreadCodec.encode(thread))
                    recoveredRows = true
                }
                if (thread.phase == .completed || thread.phase == .abandoned), thread.pendingInteraction == nil {
                    context.delete(row)
                    recoveredRows = true
                    continue
                }
                threads.append(thread)
            } catch {
                Self.log.error("mission thread \(row.threadID, privacy: .public) quarantined: \(String(describing: error), privacy: .public)")
                failures.append(MissionThreadLoadFailure(
                    id: row.threadID,
                    title: row.title,
                    reason: String(describing: error)
                ))
            }
        }

        if recoveredRows {
            do { try context.save() }
            catch {
                Self.log.error("interruption recovery save failed: \(error, privacy: .public)")
                failures.append(MissionThreadLoadFailure(
                    id: "mission-thread-recovery", title: "Recovered missions not saved",
                    reason: String(describing: error)
                ))
                context.rollback()
            }
        }
        return MissionThreadLoadBatch(
            threads: Array(threads.prefix(Self.cap)),
            failures: failures
        )
    }

    public func save(_ thread: MissionThread) throws {
        if (thread.phase == .completed || thread.phase == .abandoned), thread.pendingInteraction == nil {
            guard let row = try record(id: thread.id) else { return }
            guard thread.revision > row.revision else {
                if thread.revision < row.revision {
                    throw MissionThreadStoreError.staleRevision(stored: row.revision, incoming: thread.revision)
                }
                throw MissionThreadStoreError.conflictingRevision(thread.revision)
            }
            context.delete(row)
            try context.save()
            return
        }

        let payload = try MissionThreadCodec.encode(thread)
        if let row = try record(id: thread.id) {
            guard thread.revision >= row.revision else {
                throw MissionThreadStoreError.staleRevision(stored: row.revision, incoming: thread.revision)
            }
            if thread.revision == row.revision {
                guard payload == row.payloadData else {
                    throw MissionThreadStoreError.conflictingRevision(thread.revision)
                }
                if context.hasChanges { try context.save() }
                return
            }
            row.apply(thread, payloadData: payload)
        } else {
            context.insert(MissionThreadRecord(thread, payloadData: payload))
        }
        try evictBeyondCap()
        try context.save()
    }

    public func delete(id: String) throws {
        guard let row = try record(id: id) else { return }
        context.delete(row)
        try context.save()
    }

    public func clear() throws {
        for row in try records() { context.delete(row) }
        try context.save()
    }

    private func records() throws -> [MissionThreadRecord] {
        let descriptor = FetchDescriptor<MissionThreadRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do { return try context.fetch(descriptor) }
        catch { throw MissionThreadStoreError.fetchFailed(String(describing: error)) }
    }

    private func record(id: String) throws -> MissionThreadRecord? {
        var descriptor = FetchDescriptor<MissionThreadRecord>(
            predicate: #Predicate { $0.threadID == id }
        )
        descriptor.fetchLimit = 1
        do { return try context.fetch(descriptor).first }
        catch { throw MissionThreadStoreError.fetchFailed(String(describing: error)) }
    }

    private func evictBeyondCap() throws {
        for stale in try records().dropFirst(Self.cap) { context.delete(stale) }
    }
}

/// Fast test/screenshot store with the same revision and cap policy as SwiftData.
@MainActor
public final class InMemoryMissionThreadStore: MissionThreadStore {
    private var threads: [String: MissionThread]
    private var failures: [MissionThreadLoadFailure]
    private let clock: () -> Date

    public init(
        _ seed: [MissionThread] = [],
        failures: [MissionThreadLoadFailure] = [],
        clock: @escaping () -> Date = Date.init
    ) {
        self.threads = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
        self.failures = failures
        self.clock = clock
    }

    public func load() -> MissionThreadLoadBatch {
        var recovered: [MissionThread] = []
        for var thread in threads.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            do {
                if thread.pendingOperation != nil {
                    try thread.recoverAfterInterruption(at: clock())
                    threads[thread.id] = thread
                }
                guard thread.phase != .completed && thread.phase != .abandoned || thread.pendingInteraction != nil else {
                    threads.removeValue(forKey: thread.id)
                    continue
                }
                recovered.append(thread)
            } catch {
                failures.append(MissionThreadLoadFailure(
                    id: thread.id,
                    title: thread.goal,
                    reason: String(describing: error)
                ))
                threads.removeValue(forKey: thread.id)
            }
        }
        return MissionThreadLoadBatch(
            threads: Array(recovered.prefix(Self.cap)),
            failures: failures
        )
    }

    public func save(_ thread: MissionThread) throws {
        if (thread.phase == .completed || thread.phase == .abandoned), thread.pendingInteraction == nil {
            if let stored = threads[thread.id] {
                guard thread.revision > stored.revision else {
                    if thread.revision < stored.revision {
                        throw MissionThreadStoreError.staleRevision(
                            stored: stored.revision, incoming: thread.revision
                        )
                    }
                    throw MissionThreadStoreError.conflictingRevision(thread.revision)
                }
            }
            threads.removeValue(forKey: thread.id)
            return
        }
        var valid = thread
        try valid.validateAndNormalize()
        if let stored = threads[valid.id] {
            guard valid.revision >= stored.revision else {
                throw MissionThreadStoreError.staleRevision(stored: stored.revision, incoming: valid.revision)
            }
            guard valid.revision != stored.revision || valid == stored else {
                throw MissionThreadStoreError.conflictingRevision(valid.revision)
            }
        }
        threads[valid.id] = valid
        let keep = threads.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.cap)
            .map(\.id)
        threads = threads.filter { keep.contains($0.key) }
    }

    public func delete(id: String) throws { threads.removeValue(forKey: id) }

    public func clear() throws {
        threads.removeAll()
        failures.removeAll()
    }
}
