import Testing
import Foundation
@testable import CrumbKit

/// Tests for the "shop for someone else" foundation: the ``RecipientStore`` seam, the gift-aware
/// deterministic floors (what the sim/CI actually renders), and the History per-recipient filter.
@Suite("Recipients — store, gift voice floors, and history filter")
struct RecipientTests {

    // MARK: Fixtures

    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private static func person(_ id: String, _ name: String, daysAgo: Int) -> Recipient {
        Recipient(
            id: id, name: name, relationship: "my \(name.lowercased())",
            taste: TasteProfile(vibe: ["Quiet"], leanings: ["Muted tones"], budgetComfort: 0.5, signatureLine: ""),
            accentHex: 0x9A6A4F,
            createdAt: epoch.addingTimeInterval(TimeInterval(-daysAgo) * 86_400)
        )
    }

    private static func entry(id: String, recipient: RecipientRef?) -> HistoryEntry {
        HistoryEntry(
            id: id, goal: "g", title: "T", subtitle: "s", plan: ["a"], searchQueries: ["a"],
            curatorNote: "", accentHex: 0, recapTag: "Tag", recapLine: "Line",
            items: [HistoryItem(productID: "p", name: "Kettle", shop: SeedData.Shops.emberCoffee,
                                price: 40, variantTitle: "Standard")],
            recipient: recipient, handedOff: false, createdAt: epoch
        )
    }

    // MARK: RecipientStore — pure policy + the two stores in lockstep

    @Test("mergedRecipients upserts by id, keeps newest-first, and caps")
    @MainActor
    func mergedPolicy() {
        let mom = Self.person("mom", "Mom", daysAgo: 5)
        let dad = Self.person("dad", "Dad", daysAgo: 1)
        var roster = mergedRecipients(mom, into: [], cap: 50)
        roster = mergedRecipients(dad, into: roster, cap: 50)
        #expect(roster.map(\.id) == ["dad", "mom"])   // newest-added first

        // Upsert: same id replaces, doesn't duplicate.
        var momRenamed = mom
        momRenamed.name = "Mum"
        roster = mergedRecipients(momRenamed, into: roster, cap: 50)
        #expect(roster.count == 2)
        #expect(roster.first { $0.id == "mom" }?.name == "Mum")

        // Cap guards growth (no eviction intent, but the bound holds).
        var big: [Recipient] = []
        for i in 0..<60 { big = mergedRecipients(Self.person("p\(i)", "P\(i)", daysAgo: i), into: big, cap: 50) }
        #expect(big.count == 50)
    }

    @Test("InMemoryRecipientStore CRUD round-trips")
    @MainActor
    func inMemoryStore() {
        let store = InMemoryRecipientStore()
        store.save(Self.person("mom", "Mom", daysAgo: 2))
        store.save(Self.person("dad", "Dad", daysAgo: 1))
        #expect(store.loadRecipients().map(\.id) == ["dad", "mom"])
        store.delete(id: "dad")
        #expect(store.loadRecipients().map(\.id) == ["mom"])
    }

    @Test("SwiftDataRecipientStore round-trips taste + upserts + deletes")
    @MainActor
    func swiftDataStore() throws {
        let store = try SwiftDataRecipientStore(inMemory: true)
        let mom = Self.person("mom", "Mom", daysAgo: 1)
        store.save(mom)
        let loaded = try #require(store.loadRecipients().first)
        #expect(loaded.id == "mom")
        #expect(loaded.taste.leanings == ["Muted tones"])
        #expect(loaded.relationship == "my mom")

        var edited = mom
        edited.taste.leanings = ["Ceramic"]
        store.save(edited)
        #expect(store.loadRecipients().count == 1)                       // upsert, not insert
        #expect(store.loadRecipients().first?.taste.leanings == ["Ceramic"])

        store.delete(id: "mom")
        #expect(store.loadRecipients().isEmpty)
    }

    @Test("RecipientRef projects the lean snapshot")
    func refProjection() {
        let mom = Self.person("mom", "Mom", daysAgo: 0)
        let ref = mom.ref
        #expect(ref.id == "mom")
        #expect(ref.name == "Mom")
        #expect(ref.accentHex == mom.accentHex)
        #expect(ref.trimmedRelationship == "my mom")
    }

    // MARK: Gift-aware deterministic floors (what the sim/CI renders + is the unit-tested guarantee)

    @Test("RuleBasedCurator voices a gift to the recipient by name; owner voice is unchanged")
    func giftRationale() {
        // A leaning whose keyword can't echo in any seed rationale, so we hit the "Fits … lean" branch.
        let profile = TasteProfile(vibe: [], leanings: ["Zylophone tones"], budgetComfort: 0.5, signatureLine: "")
        let product = SeedData.hikeProducts[0]
        let curator = RuleBasedCurator()
        let mom = RecipientRef(id: "m", name: "Mom", accentHex: 0)

        let owner = curator.rationale(for: product, profile: profile)
        let gift = curator.rationale(for: product, profile: profile, recipient: mom)

        #expect(owner.contains("your lean toward"))
        #expect(gift.contains("Mom's lean toward"))
        #expect(!gift.contains("your lean toward"))
    }

    @Test("RuleBasedRecapWriter.line is gift-aware: '— a gift for <name>'")
    func giftRecapLine() {
        let facts = [RecapFact(name: "Kettle", shop: "Ember", price: 40)]
        let profile = SeedData.defaultTasteProfile
        let mom = RecipientRef(id: "m", name: "Mom", accentHex: 0)

        let owner = RuleBasedRecapWriter.line(items: facts, profile: profile)
        let gift = RuleBasedRecapWriter.line(items: facts, profile: profile, recipient: mom)

        #expect(!owner.lowercased().contains("gift"))
        #expect(gift.contains("a gift for Mom"))
        #expect(gift.hasSuffix("."))
    }

    @Test("The full rule-based recap carries the gift framing in its line")
    func giftRecapFull() {
        let facts = [RecapFact(name: "Kettle", shop: "Ember", price: 40)]
        let mom = RecipientRef(id: "m", name: "Mom", accentHex: 0)
        let recap = RuleBasedRecapWriter.recap(
            goal: "a pour-over corner", plan: [], items: facts,
            profile: SeedData.defaultTasteProfile, recipient: mom, reason: nil
        )
        #expect(recap.line.contains("a gift for Mom"))
    }

    // MARK: History per-recipient filter

    @Test("HistoryFacets derives All · You · each person, and apply narrows correctly")
    func facetsAndApply() {
        let momRef = RecipientRef(id: "mom", name: "Mom", accentHex: 0x9A6A4F)
        let gift = Self.entry(id: "gift", recipient: momRef)
        let owned = Self.entry(id: "owned", recipient: nil)
        let entries = [gift, owned]

        let facets = HistoryFacets.facets(entries, ownerAccentHex: 0x1C4B43)
        #expect(facets.map(\.id) == ["all", "yourself", "person-mom"])
        #expect(facets.first { $0.id == "person-mom" }?.label == "Mom")
        #expect(facets.first { $0.id == "yourself" }?.accentHex == 0x1C4B43)

        #expect(HistoryFacets.apply(.all, to: entries).map(\.id) == ["gift", "owned"])
        #expect(HistoryFacets.apply(.yourself, to: entries).map(\.id) == ["owned"])
        #expect(HistoryFacets.apply(.person("mom"), to: entries).map(\.id) == ["gift"])
    }

    @Test("A history with no gifts yields only All · You (no filter row needed)")
    func facetsNoGifts() {
        let facets = HistoryFacets.facets([Self.entry(id: "a", recipient: nil)], ownerAccentHex: 0x1C4B43)
        #expect(facets.map(\.id) == ["all", "yourself"])
    }

    @Test("HistoryEntry round-trips its recipient through SwiftData (old rows decode to nil)")
    @MainActor
    func historyRecipientRoundTrip() throws {
        let store = try SwiftDataHistoryStore(inMemory: true)
        let momRef = RecipientRef(id: "mom", name: "Mom", relationship: "my mom", accentHex: 0x9A6A4F)
        store.save(Self.entry(id: "gift", recipient: momRef))
        store.save(Self.entry(id: "owned", recipient: nil))

        let byID = Dictionary(uniqueKeysWithValues: store.loadEntries().map { ($0.id, $0) })
        #expect(byID["gift"]?.recipient?.name == "Mom")
        #expect(byID["gift"]?.recipient?.relationship == "my mom")
        #expect(byID["owned"]?.recipient == nil)
    }
}
