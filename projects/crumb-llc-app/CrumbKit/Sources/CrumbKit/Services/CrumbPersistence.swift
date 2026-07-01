import Foundation
import SwiftData
import os

/// The single SwiftData container that backs **all** persisted stores.
///
/// SwiftData writes one `default.store` SQLite file per process when a `ModelConfiguration`
/// is given no explicit URL. A container is created for a specific set of `@Model` types and
/// physically creates a table only for *those* entities. So building a **separate** container
/// per store — each declaring a different single entity — and letting them all fall back to
/// the same `default.store` file makes them collide: the first container to open stamps the
/// file with its one table, and every other store then fails every fetch/save with
/// `no such table: Z…RECORD`. That failure is swallowed by the stores' best-effort `try?`,
/// so nothing persists and nothing crashes — it just silently stops working.
///
/// Building **one** container over the union of every persisted entity keeps taste, recents,
/// history, and recipients all readable from the same file. Any new persisted `@Model` MUST be
/// added to ``models`` here, or it will reintroduce the same collision.
public enum CrumbPersistence {
    private static let log = Logger(subsystem: "llc.crumb.CrumbKit", category: "Persistence")

    /// Every persisted `@Model` type, unioned into one schema.
    public static let models: [any PersistentModel.Type] = [
        TasteProfileRecord.self,
        RecentMissionRecord.self,
        HistoryEntryRecord.self,
        RecipientRecord.self,
    ]

    /// Builds the one shared container over the union schema. `inMemory` keeps everything in
    /// RAM (the path tests and screenshots use). Throws if SwiftData can't open the store — the
    /// caller degrades to in-memory stores so a storage failure never blocks launch.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            log.error("shared ModelContainer failed to open — persistence disabled this session: \(error, privacy: .public)")
            throw error
        }
    }
}
