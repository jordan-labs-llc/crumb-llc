import Foundation
import SwiftData
import os

/// Persists the user's ``TasteProfile`` across launches.
///
/// The profile is the one piece of state that must survive a relaunch (the kit, mission,
/// and order are session-scoped today). The store is a seam so the app can persist with
/// SwiftData in production while tests round-trip against an in-memory double — mirroring
/// how ``UCPClient`` and ``CuratorEngine`` are injected.
///
/// `@MainActor` because the SwiftData implementation reads/writes the container's
/// `mainContext`, and ``AppModel`` (the only caller) is already `@MainActor`.
@MainActor
public protocol TasteStore {
    /// The persisted profile, or `nil` when the user has never saved one (a first run —
    /// ``AppModel`` reads this to decide whether to open onboarding).
    func loadProfile() -> TasteProfile?

    /// Persists `profile`, replacing any previously saved one.
    func saveProfile(_ profile: TasteProfile)
}

/// The SwiftData-backed ``TasteStore`` used by the app. A single ``TasteProfileRecord`` row
/// holds the current profile; saving upserts that row. The schema is deliberately a bit
/// roomier than today's needs (`updatedAt`) so it can grow to carry kit / order history in a
/// later pass without a migration churn.
@MainActor
public final class SwiftDataTasteStore: TasteStore {
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "Persistence")
    private let container: ModelContainer

    private var context: ModelContext { container.mainContext }

    /// Wraps an existing container (e.g. one shared with future stores).
    public init(container: ModelContainer) {
        self.container = container
    }

    /// Builds a store over its own container. `inMemory` keeps everything in RAM — the path
    /// tests use to round-trip the *real* SwiftData stack without touching disk.
    public convenience init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try ModelContainer(
            for: TasteProfileRecord.self,
            configurations: configuration
        )
        self.init(container: container)
    }

    public func loadProfile() -> TasteProfile? {
        currentRecord()?.profile
    }

    public func saveProfile(_ profile: TasteProfile) {
        if let record = currentRecord() {
            record.apply(profile)
        } else {
            context.insert(TasteProfileRecord(profile))
        }
        // Best-effort: a failed taste save must never crash the app mid-edit. The in-memory
        // value in `AppModel` stays authoritative for the session either way — but log it, so a
        // silent persistence failure can't hide the way the store-collision bug once did.
        do {
            try context.save()
        } catch {
            Self.log.error("taste save failed: \(error, privacy: .public)")
        }
    }

    /// The single profile row, if one has been saved. (We keep exactly one; `fetchLimit: 1`
    /// guards against a stray duplicate ever ordering the result non-deterministically.)
    private func currentRecord() -> TasteProfileRecord? {
        var descriptor = FetchDescriptor<TasteProfileRecord>()
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The persisted shape of a ``TasteProfile``. Stored as a single upserted row by
/// ``SwiftDataTasteStore``. Kept distinct from the value-type ``TasteProfile`` so the domain
/// model stays a `Sendable` struct the curator can pass around freely.
@Model
public final class TasteProfileRecord {
    public var vibe: [String]
    public var leanings: [String]
    public var budgetComfort: Double
    public var signatureLine: String
    /// When this profile was last written — present so the schema can later disambiguate
    /// history rows without a migration.
    public var updatedAt: Date

    public init(_ profile: TasteProfile, updatedAt: Date = .init()) {
        self.vibe = profile.vibe
        self.leanings = profile.leanings
        self.budgetComfort = profile.budgetComfort
        self.signatureLine = profile.signatureLine
        self.updatedAt = updatedAt
    }

    /// The domain value this row represents.
    public var profile: TasteProfile {
        TasteProfile(
            vibe: vibe,
            leanings: leanings,
            budgetComfort: budgetComfort,
            signatureLine: signatureLine
        )
    }

    /// Overwrites this row's fields with `profile` (the upsert path).
    public func apply(_ profile: TasteProfile, updatedAt: Date = .init()) {
        vibe = profile.vibe
        leanings = profile.leanings
        budgetComfort = profile.budgetComfort
        signatureLine = profile.signatureLine
        self.updatedAt = updatedAt
    }
}

/// A throwaway in-memory ``TasteStore`` for tests and the mock scaffold: no SwiftData, no
/// disk. Seed it with a profile to simulate a returning user, or leave it empty to simulate
/// a first run (so ``AppModel`` opens onboarding).
@MainActor
public final class InMemoryTasteStore: TasteStore {
    private var profile: TasteProfile?

    public init(_ seed: TasteProfile? = nil) {
        self.profile = seed
    }

    public func loadProfile() -> TasteProfile? { profile }

    public func saveProfile(_ profile: TasteProfile) { self.profile = profile }
}
