import Testing
import Foundation
import SwiftData
@testable import CrumbKit

/// Regression guard for the store-collision bug: four `@Model` types (taste, recents, history,
/// recipients) each used to build their **own** `ModelContainer`, and each container defaulted to
/// the *same* `default.store` file. SwiftData writes only the schema it was given, so the first
/// container to open created its one table and the rest hit `no such table` — silently, because
/// every write was a `try?`. The fix (`CrumbPersistence`) opens **one** shared container over the
/// union schema so all four tables live in one file.
///
/// These tests run the real SwiftData stack against an **on-disk** store and reopen a *fresh*
/// container at the same URL — a faithful stand-in for an app relaunch, which is where the bug bit.
@Suite("Persistence")
struct PersistenceTests {

    /// Opens a shared container over `CrumbPersistence.models` at a fixed on-disk `url` — the same
    /// union schema the app uses, so the test exercises the exact table set that used to collide.
    @MainActor
    private func sharedContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(CrumbPersistence.models)
        let configuration = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// The core acceptance test for Phase 1: write through **all four** stores on one shared on-disk
    /// container, drop it (app quit), reopen a fresh one at the same file (relaunch), and require
    /// every store reads its row back. Pre-fix this threw / returned empty for three of the four,
    /// because their tables never existed in the shared file.
    @Test("All four stores coexist on one file and survive a relaunch")
    @MainActor
    func sharedContainerSurvivesRelaunch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crumb-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")

        let taste = TasteProfile(vibe: ["calm"], leanings: ["earthy"],
                                 budgetComfort: 0.4, signatureLine: "quiet and earthy")
        let person = Recipient(id: "r1", name: "Mom", relationship: "mother",
                               taste: taste, accentHex: 0x1C4B43, createdAt: Date(timeIntervalSince1970: 1_000))
        let past = HistoryEntry(
            id: "h1", goal: "premium jasmine tea", title: "Jasmine, done right",
            subtitle: "3 picks", plan: ["find loose-leaf jasmine"], searchQueries: ["jasmine tea"],
            curatorNote: "note", accentHex: 0x1C4B43, recapTag: "Tea", recapLine: "A calm cup.",
            items: [], recipient: person.ref, handedOff: true, createdAt: Date(timeIntervalSince1970: 2_000))

        // First launch: write one row through every store, then let the container deallocate.
        try {
            let container = try sharedContainer(at: url)
            SwiftDataTasteStore(container: container).saveProfile(taste)
            SwiftDataRecentMissionsStore(container: container).addRecent("premium jasmine tea")
            SwiftDataHistoryStore(container: container).save(past)
            SwiftDataRecipientStore(container: container).save(person)
        }()

        // Relaunch: a fresh container on the same file must read every row back — no `no such table`.
        let container = try sharedContainer(at: url)
        let loadedTaste = try #require(SwiftDataTasteStore(container: container).loadProfile())
        #expect(loadedTaste.signatureLine == "quiet and earthy")
        #expect(SwiftDataRecentMissionsStore(container: container).loadRecents() == ["premium jasmine tea"])

        let loadedHistory = SwiftDataHistoryStore(container: container).loadEntries()
        #expect(loadedHistory.map(\.id) == ["h1"])
        #expect(loadedHistory.first?.recipient?.name == "Mom")

        let loadedPeople = SwiftDataRecipientStore(container: container).loadRecipients()
        #expect(loadedPeople.map(\.id) == ["r1"])
        #expect(loadedPeople.first?.taste.signatureLine == "quiet and earthy")
    }

    /// A second write on a *later* "launch" must land alongside the first — proving the reopened
    /// container is genuinely the same store, not a fresh empty one that merely happens to write.
    @Test("A write on a later launch accretes onto the existing file")
    @MainActor
    func writesAccreteAcrossLaunches() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crumb-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")

        try {
            let container = try sharedContainer(at: url)
            SwiftDataRecentMissionsStore(container: container).addRecent("first goal")
        }()
        try {
            let container = try sharedContainer(at: url)
            SwiftDataRecentMissionsStore(container: container).addRecent("second goal")
        }()

        let container = try sharedContainer(at: url)
        // Most-recent-first, both rows present — the second launch saw the first launch's write.
        #expect(SwiftDataRecentMissionsStore(container: container).loadRecents() == ["second goal", "first goal"])
    }
}
