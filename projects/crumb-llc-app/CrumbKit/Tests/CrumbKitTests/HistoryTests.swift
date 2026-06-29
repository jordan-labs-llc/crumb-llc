import Testing
import Foundation
@testable import CrumbKit

/// Exhaustive tests for the History layer: the pure timeline grouping + stats, the recap writer's
/// deterministic floor and reconcile, and the store's dedupe / cap / round-trip guarantees. The
/// model-backed recap call stays untested (the on-device model is unavailable on CI/sim — the recap
/// always hits the rule-based floor there), mirroring the other Foundation Models seams.
@Suite("History")
struct HistoryTests {

    // MARK: - Fixtures

    /// A fixed reference instant so timeline grouping is deterministic (no wall-clock).
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000) // 2026-05-09-ish

    /// UTC gregorian calendar so day/week boundaries don't depend on the test host's locale.
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    func item(_ id: String, shop: String, price: Decimal = 10, buyURL: URL? = nil) -> HistoryItem {
        HistoryItem(
            productID: id, name: id.capitalized, shop: Shop(id: shop, name: shop.capitalized),
            price: price, variantTitle: "Standard", imageURL: nil, buyURL: buyURL
        )
    }

    func entry(
        _ id: String,
        daysAgo: Int,
        items: [HistoryItem]? = nil,
        handedOff: Bool = false
    ) -> HistoryEntry {
        HistoryEntry(
            id: id, goal: "goal \(id)", title: "Title \(id)", subtitle: "sub",
            plan: ["p1"], searchQueries: ["q1"], curatorNote: "note", accentHex: 0x1C4B43,
            recapTag: "Tag", recapLine: "Line",
            items: items ?? [item("a", shop: "s1")], handedOff: handedOff,
            createdAt: Self.now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400)
        )
    }

    // MARK: - Timeline grouping (pure)

    @Test("Entries fall into Today / This week / Earlier by age relative to an injected now")
    func timelineBuckets() {
        let entries = [
            entry("today", daysAgo: 0),
            entry("yesterday", daysAgo: 1),
            entry("sixDays", daysAgo: 6),
            entry("nineDays", daysAgo: 9),
            entry("monthAgo", daysAgo: 30),
        ]
        let sections = HistoryTimeline.sections(entries, now: Self.now, calendar: Self.utc)

        #expect(sections.map(\.bucket) == [.today, .thisWeek, .earlier])
        #expect(sections[0].entries.map(\.id) == ["today"])
        #expect(Set(sections[1].entries.map(\.id)) == ["yesterday", "sixDays"])
        #expect(Set(sections[2].entries.map(\.id)) == ["nineDays", "monthAgo"])
    }

    @Test("Empty buckets are omitted; input recency order is preserved within a section")
    func timelineOmitsEmptyAndKeepsOrder() {
        let entries = [entry("a", daysAgo: 10), entry("b", daysAgo: 20)] // both Earlier
        let sections = HistoryTimeline.sections(entries, now: Self.now, calendar: Self.utc)
        #expect(sections.count == 1)
        #expect(sections[0].bucket == .earlier)
        #expect(sections[0].entries.map(\.id) == ["a", "b"]) // order preserved
    }

    @Test("No entries yields no sections")
    func timelineEmpty() {
        #expect(HistoryTimeline.sections([], now: Self.now, calendar: Self.utc).isEmpty)
    }

    // MARK: - Stats (pure)

    @Test("Stats aggregate kits, items, distinct shops, and the earliest date")
    func statsAggregate() {
        let entries = [
            entry("a", daysAgo: 1, items: [item("a1", shop: "s1"), item("a2", shop: "s2")]),
            entry("b", daysAgo: 5, items: [item("b1", shop: "s1")]),   // s1 repeats — distinct count
        ]
        let stats = HistoryStats(entries: entries)
        #expect(stats.kitCount == 2)
        #expect(stats.itemCount == 3)
        #expect(stats.shopCount == 2)            // s1, s2 — deduped across entries
        #expect(stats.since == entries[1].createdAt) // the oldest (5 days ago)
        #expect(!stats.isEmpty)
    }

    @Test("Empty stats report zero and isEmpty")
    func statsEmpty() {
        let stats = HistoryStats(entries: [])
        #expect(stats.isEmpty)
        #expect(stats.kitCount == 0)
        #expect(stats.since == nil)
        #expect(!stats.isMilestone)
    }

    @Test("Milestones trigger only on the round kit counts")
    func statsMilestones() {
        for n in [5, 10, 25, 50] {
            let entries = (0..<n).map { entry("e\($0)", daysAgo: $0) }
            #expect(HistoryStats(entries: entries).isMilestone, "count \(n) should be a milestone")
        }
        for n in [1, 4, 6, 11, 49] {
            let entries = (0..<n).map { entry("e\($0)", daysAgo: $0) }
            #expect(!HistoryStats(entries: entries).isMilestone, "count \(n) should NOT be a milestone")
        }
    }

    // MARK: - Entry derived

    @Test("An entry derives subtotal, distinct shops in first-seen order, and per-shop slices")
    func entryDerived() {
        let e = entry("a", daysAgo: 0, items: [
            item("x", shop: "s1", price: 5),
            item("y", shop: "s2", price: 7),
            item("z", shop: "s1", price: 3),
        ])
        #expect(e.subtotal == 15)
        #expect(e.shops.map(\.id) == ["s1", "s2"])     // first-seen order
        #expect(e.shopCount == 2)
        #expect(e.items(for: Shop(id: "s1", name: "S1")).map(\.productID) == ["x", "z"])
        #expect(e.subtotal(for: Shop(id: "s1", name: "S1")) == 8)
        #expect(e.withHandedOff(true).handedOff)
    }

    // MARK: - Rule-based recap (pure floor)

    @Test("The recap tag strips leading filler and title-cases the goal's key words")
    func recapTag() {
        #expect(RuleBasedRecapWriter.tag(forGoal: "Pack me for a rainy weekend hike") == "Rainy Weekend Hike kit")
        #expect(RuleBasedRecapWriter.tag(forGoal: "set up my pour-over corner") == "Pour Over Corner kit")
        #expect(RuleBasedRecapWriter.tag(forGoal: "   ") == "Your kit")        // nothing usable
        // Caps at maxTagWords content words so a long goal can't blow out the card.
        #expect(RuleBasedRecapWriter.tag(forGoal: "build one two three four five six").split(separator: " ").count
            == RuleBasedRecapWriter.maxTagWords + 1) // + "kit"
    }

    @Test("The recap line states piece + shop counts and the top leaning, pluralized")
    func recapLine() {
        let profile = TasteProfile(vibe: [], leanings: ["Durable"], budgetComfort: 0.5, signatureLine: "")
        let one = RuleBasedRecapWriter.line(items: [RecapFact(name: "a", shop: "S1", price: 1)], profile: profile)
        #expect(one == "1 piece from 1 shop, leaning durable.")

        let many = RuleBasedRecapWriter.line(
            items: [
                RecapFact(name: "a", shop: "S1", price: 1),
                RecapFact(name: "b", shop: "S2", price: 1),
            ],
            profile: profile
        )
        #expect(many == "2 pieces from 2 shops, leaning durable.")

        // No leaning → no trailing clause, still honest.
        let bare = TasteProfile(vibe: [], leanings: [], budgetComfort: 0.5, signatureLine: "")
        let noLean = RuleBasedRecapWriter.line(items: [RecapFact(name: "a", shop: "S1", price: 1)], profile: bare)
        #expect(noLean == "1 piece from 1 shop.")
    }

    @Test("The rule-based writer reports the chosen-default tier (quiet, no note)")
    func recapWriterDefaultTier() async {
        let profile = TasteProfile(vibe: [], leanings: ["Quiet"], budgetComfort: 0.5, signatureLine: "")
        let recap = await RuleBasedRecapWriter().writeRecap(
            goal: "pack me for a hike", plan: ["shell"],
            items: [RecapFact(name: "Shell", shop: "Northbound", price: 200)], profile: profile
        )
        #expect(recap.tier == .ruleBased(nil))
        #expect(recap.tier.fallbackNote == nil)
        #expect(recap.tag == "Hike kit")
        #expect(!recap.line.isEmpty)
    }

    // MARK: - Apple Foundation recap reconcile (pure — model call untested)

    @Test("Reconcile keeps a well-formed model draft, trimmed")
    func reconcileKeepsModelDraft() {
        let draft = RecapDraft(tag: "  Rainy-hike kit  ", line: "  Quiet, waterproof, built to last  ")
        let recap = AppleFoundationRecapWriter.recap(
            from: draft, goal: "pack me for a hike", plan: ["shell"],
            items: [RecapFact(name: "Shell", shop: "N", price: 1)],
            profile: SeedData.defaultTasteProfile, tier: .onDevice
        )
        #expect(recap.tag == "Rainy-hike kit")
        #expect(recap.line == "Quiet, waterproof, built to last")
        #expect(recap.tier == .onDevice)
    }

    @Test("Reconcile backfills blank model fields from the deterministic floor")
    func reconcileBackfillsBlanks() {
        let draft = RecapDraft(tag: "   ", line: "")
        let items = [RecapFact(name: "Shell", shop: "N", price: 1)]
        let recap = AppleFoundationRecapWriter.recap(
            from: draft, goal: "pack me for a hike", plan: ["shell"],
            items: items, profile: SeedData.defaultTasteProfile, tier: .onDevice
        )
        #expect(recap.tag == RuleBasedRecapWriter.tag(forGoal: "pack me for a hike"))
        #expect(recap.line == RuleBasedRecapWriter.line(items: items, profile: SeedData.defaultTasteProfile))
    }

    @Test("Reconcile caps a runaway line on a word boundary")
    func reconcileCapsLongLine() {
        let long = String(repeating: "word ", count: 60)
        let recap = AppleFoundationRecapWriter.recap(
            from: RecapDraft(tag: "Tag", line: long), goal: "g", plan: [],
            items: [RecapFact(name: "a", shop: "s", price: 1)],
            profile: SeedData.defaultTasteProfile, tier: .onDevice
        )
        #expect(recap.line.count <= AppleFoundationRecapWriter.maxLineLength + 1) // + ellipsis
        #expect(recap.line.hasSuffix("…"))
    }

    // MARK: - mergedEntries (pure)

    @Test("mergedEntries upserts by id, keeps most-recent-first, and caps oldest-first")
    @MainActor
    func mergeUpsertsAndCaps() {
        let existing = [entry("a", daysAgo: 1), entry("b", daysAgo: 2)]
        // Update "a" with a newer copy (same id) → still one "a", moved by createdAt.
        let updatedA = entry("a", daysAgo: 0)
        let merged = mergedEntries(updatedA, into: existing, cap: 50)
        #expect(merged.map(\.id) == ["a", "b"])           // a is newest now
        #expect(merged.count == 2)                        // upsert, not duplicate

        // Cap evicts the oldest.
        let many = (0..<5).map { entry("e\($0)", daysAgo: $0) } // e0 newest … e4 oldest
        let capped = mergedEntries(entry("new", daysAgo: 0), into: many, cap: 3)
        #expect(capped.count == 3)
        #expect(!capped.contains { $0.id == "e4" })       // oldest dropped
    }

    // MARK: - InMemory store

    @Test("InMemoryHistoryStore round-trips save / handedOff / delete / clear")
    @MainActor
    func inMemoryStore() {
        let store = InMemoryHistoryStore()
        store.save(entry("a", daysAgo: 1))
        store.save(entry("b", daysAgo: 0))
        #expect(store.loadEntries().map(\.id) == ["b", "a"]) // most-recent-first

        // Upsert same id.
        store.save(entry("a", daysAgo: 1, handedOff: false))
        #expect(store.loadEntries().count == 2)

        store.setHandedOff("a", true)
        #expect(store.loadEntries().first { $0.id == "a" }?.handedOff == true)

        store.delete(id: "a")
        #expect(store.loadEntries().map(\.id) == ["b"])

        store.clear()
        #expect(store.loadEntries().isEmpty)
    }

    @Test("InMemoryHistoryStore seeds most-recent-first and respects the cap")
    @MainActor
    func inMemorySeedCap() {
        let seed = (0..<60).map { entry("e\($0)", daysAgo: $0) }
        let store = InMemoryHistoryStore(seed)
        #expect(store.loadEntries().count == 50)               // capped
        #expect(store.loadEntries().first?.id == "e0")         // newest first
    }

    // MARK: - SwiftData store (real stack, in-memory container)

    @Test("SwiftDataHistoryStore round-trips an entry with its snapshotted items")
    @MainActor
    func swiftDataRoundTrip() throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        let e = entry("a", daysAgo: 0, items: [
            item("x", shop: "s1", price: 5, buyURL: URL(string: "https://shop.example/x")),
            item("y", shop: "s2", price: 7),
        ], handedOff: true)
        store.save(e)

        let loaded = try #require(store.loadEntries().first)
        #expect(loaded.id == "a")
        #expect(loaded.items.map(\.productID) == ["x", "y"])    // items survive the JSON blob
        #expect(loaded.items.first?.buyURL == URL(string: "https://shop.example/x"))
        #expect(loaded.subtotal == 12)
        #expect(loaded.handedOff)
        #expect(loaded.accentHex == 0x1C4B43)                    // UInt32 ↔ Int round-trips
    }

    @Test("SwiftDataHistoryStore upserts by id, flips outcome, deletes, clears, and caps")
    @MainActor
    func swiftDataMutations() throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        store.save(entry("a", daysAgo: 1))
        store.save(entry("a", daysAgo: 1, handedOff: false)) // same id → upsert
        #expect(store.loadEntries().count == 1)

        store.setHandedOff("a", true)
        #expect(store.loadEntries().first?.handedOff == true)

        store.save(entry("b", daysAgo: 0))
        #expect(store.loadEntries().map(\.id) == ["b", "a"])  // newest-first

        store.delete(id: "a")
        #expect(store.loadEntries().map(\.id) == ["b"])

        store.clear()
        #expect(store.loadEntries().isEmpty)
    }

    @Test("SwiftDataHistoryStore evicts the oldest beyond the cap")
    @MainActor
    func swiftDataCap() throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        for i in 0..<(SwiftDataHistoryStore.cap + 5) {
            store.save(entry("e\(i)", daysAgo: SwiftDataHistoryStore.cap + 5 - i)) // e0 oldest … newest last
        }
        let loaded = store.loadEntries()
        #expect(loaded.count == SwiftDataHistoryStore.cap)
        #expect(!loaded.contains { $0.id == "e0" })    // the oldest was evicted
    }
}
