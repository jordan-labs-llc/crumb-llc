import Testing
import Foundation
@testable import CrumbKit

@Suite("Taste capture — persistence, extraction, and profile-driven ranking")
struct TasteCaptureTests {

    // MARK: Persistence (real SwiftData stack, in-memory)

    @Test("SwiftDataTasteStore round-trips a saved profile")
    @MainActor
    func swiftDataRoundTrip() throws {
        let store = try SwiftDataTasteStore(inMemory: true)
        #expect(store.loadProfile() == nil)   // first run: nothing persisted

        let profile = TasteProfile(
            vibe: ["Quiet", "Earthy"],
            leanings: ["Merino over synthetic"],
            budgetComfort: 0.42,
            signatureLine: "A few things I love."
        )
        store.saveProfile(profile)

        let loaded = store.loadProfile()
        #expect(loaded == profile)
    }

    @Test("Saving twice upserts a single row (latest wins)")
    @MainActor
    func swiftDataUpsert() throws {
        let store = try SwiftDataTasteStore(inMemory: true)
        store.saveProfile(SeedData.defaultTasteProfile)

        let edited = TasteProfile(
            vibe: ["Bold"], leanings: ["Tech-forward"],
            budgetComfort: 0.9, signatureLine: "Give me the best."
        )
        store.saveProfile(edited)

        #expect(store.loadProfile() == edited)   // replaced, not appended
    }

    @Test("InMemoryTasteStore reports nil until seeded/saved")
    @MainActor
    func inMemoryStore() {
        let empty = InMemoryTasteStore()
        #expect(empty.loadProfile() == nil)

        let seeded = InMemoryTasteStore(SeedData.defaultTasteProfile)
        #expect(seeded.loadProfile() == SeedData.defaultTasteProfile)

        empty.saveProfile(SeedData.defaultTasteProfile)
        #expect(empty.loadProfile() == SeedData.defaultTasteProfile)
    }

    // MARK: Extraction — the manual fallback and the conservative merge

    @Test("ManualTasteExtractor never parses (always manual)")
    func manualExtractorReturnsNil() async {
        let result = await ManualTasteExtractor().extract(
            from: "quiet earthy gear, merino over synthetic",
            base: SeedData.defaultTasteProfile
        )
        #expect(result == nil)
    }

    @Test("merge tops up empty fields from the base and keeps non-empty model fields")
    func mergeFallsBackToBase() {
        let base = SeedData.defaultTasteProfile
        // Model only spoke to vibe + budget; leanings/signature blank → keep the base's.
        let extracted = ExtractedTaste(
            vibe: ["Playful", "Bright"],
            leanings: [],
            budgetComfort: 0.3,
            signatureLine: "   "
        )
        let merged = AppleFoundationTasteExtractor.merge(extracted, into: base)

        #expect(merged.vibe == ["Playful", "Bright"])      // model's words win
        #expect(merged.leanings == base.leanings)           // blank → base
        #expect(merged.signatureLine == base.signatureLine) // whitespace → base
        #expect(merged.budgetComfort == 0.3)
    }

    @Test("merge clamps budget to 0…1 and cleans chip lists")
    func mergeClampsAndCleans() {
        let base = SeedData.defaultTasteProfile
        let extracted = ExtractedTaste(
            vibe: ["  Quiet ", "quiet", "", "Earthy"],   // dupe (case-insensitive) + blank
            leanings: ["Muted tones"],
            budgetComfort: 1.8,                           // out of range
            signatureLine: "Mine."
        )
        let merged = AppleFoundationTasteExtractor.merge(extracted, into: base)

        #expect(merged.vibe == ["Quiet", "Earthy"])       // trimmed + deduped, first spelling
        #expect(merged.budgetComfort == 1.0)              // clamped
    }

    @Test("clean dedupes case-insensitively and caps the list length")
    func cleanCaps() {
        let many = (0..<20).map { "Tag\($0)" }
        #expect(AppleFoundationTasteExtractor.clean(many).count == AppleFoundationTasteExtractor.maxChips)
        #expect(AppleFoundationTasteExtractor.clean(["A", "a", " A "]) == ["A"])
    }

    // MARK: Normalization

    @Test("TasteProfile.normalized trims, dedupes, and clamps")
    func normalized() {
        let messy = TasteProfile(
            vibe: [" Quiet ", "quiet", "Earthy", ""],
            leanings: ["Merino", "merino"],
            budgetComfort: -0.5,
            signatureLine: "  trimmed  "
        )
        let clean = messy.normalized
        #expect(clean.vibe == ["Quiet", "Earthy"])
        #expect(clean.leanings == ["Merino"])
        #expect(clean.budgetComfort == 0.0)
        #expect(clean.signatureLine == "trimmed")
    }

    // MARK: Profile drives ranking (the felt-personalization guarantee)

    @Test("Flipping budget comfort visibly re-ranks the deck")
    func budgetReranksDeck() async {
        let curator = RuleBasedCurator()
        let products = SeedData.hikeProducts

        let thrifty = TasteProfile(
            vibe: [], leanings: SeedData.defaultTasteProfile.leanings,
            budgetComfort: 0.0, signatureLine: ""
        )
        let splurge = TasteProfile(
            vibe: [], leanings: SeedData.defaultTasteProfile.leanings,
            budgetComfort: 1.0, signatureLine: ""
        )

        let thriftyOrder = await curator.rank(products, for: thrifty).map(\.id)
        let splurgeOrder = await curator.rank(products, for: splurge).map(\.id)

        // Same set, different order — taste actually moves the deck.
        #expect(Set(thriftyOrder) == Set(splurgeOrder))
        #expect(thriftyOrder != splurgeOrder)
    }
}
