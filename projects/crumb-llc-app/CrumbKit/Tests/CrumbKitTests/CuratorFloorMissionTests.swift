import Testing
import Foundation
@testable import CrumbKit

/// Tests for the **mission-aware** deterministic curator floor (#33): the line that renders
/// whenever the on-device model can't voice a card (offline, cold start, per-card voice failure).
/// Before #33 it leaned on the user's first stated leaning with no mission context, so against the
/// skipped-onboarding default profile it read off-topic — "…your lean toward merino over synthetic."
/// on a **jasmine tea** card. The floor now anchors to the mission and only names a leaning that
/// genuinely fits, while `mission == nil` reproduces the old line byte-for-byte.
@Suite("Curator floor — mission-aware voice (#33)")
struct CuratorFloorMissionTests {

    private let curator = RuleBasedCurator()

    // MARK: Fixtures

    /// A jasmine-tea mission whose title/subtitle share no vocabulary with the default hiking taste.
    private static let teaMission = ShoppingTask(
        id: "goal.premium-jasmine-tea",
        title: "Premium jasmine tea",
        subtitle: "A mission for you",
        plan: ["Loose-leaf jasmine tea"],
        curatorNote: "",
        accentHex: 0,
        candidateIDs: [],
        searchQueries: ["premium jasmine tea"]
    )

    /// The skipped-onboarding default taste — its leadmost leaning is "Merino over synthetic",
    /// which is exactly the off-topic phrase #33 is about.
    private static let defaultTaste = SeedData.defaultTasteProfile

    /// A live catalog card whose rationale is the raw merchant blurb (echoes no leaning), so the
    /// floor has to speak in its own voice.
    private static func teaCard(_ blurb: String = "Premium loose jasmine green tea leaves, 8.46 oz bag.") -> Product {
        Product(
            id: "live.tea", name: "Jasmine Tea", shop: Shop(id: "s", name: "thefoalyard.co.uk"),
            price: 17, rating: 0, reviews: 0, rationale: blurb, symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "live.tea.v", title: "Standard", price: 17, checkoutURL: nil)]
        )
    }

    private static let mom = RecipientRef(id: "mom", name: "Mom", accentHex: 0)

    // MARK: Owner voice — the core off-topic fix

    @Test("Owner floor names concrete tea-quality signals and drops an off-topic default leaning (#33/#58)")
    func ownerReadsOnTopic() {
        let line = curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste,
                                     recipient: nil, mission: Self.teaMission)
        // #58: the generic "A steady pick for …" floor is replaced by concrete quality copy — the
        // loose-leaf card reads as a genuine premium pick, not just an echo of the mission title.
        #expect(line.lowercased().contains("loose-leaf"))
        #expect(line.lowercased().contains("premium"))
        #expect(!line.lowercased().contains("merino"))   // the off-topic leaning is gone
        #expect(!line.lowercased().contains("synthetic"))
    }

    @Test("Owner floor keeps a leaning that genuinely fits the mission, alongside the mission")
    func ownerKeepsFittingLeaning() {
        // "Loose-leaf over bags" → keyword "loose-leaf" appears in the mission plan-derived title.
        let mission = ShoppingTask(
            id: "goal.loose-leaf-jasmine", title: "Loose-leaf jasmine tea", subtitle: "Bright + floral",
            plan: ["Tea"], curatorNote: "", accentHex: 0, candidateIDs: [], searchQueries: ["tea"]
        )
        let taste = TasteProfile(vibe: [], leanings: ["Loose-leaf over bags"], budgetComfort: 0.5, signatureLine: "")
        let line = curator.rationale(for: Self.teaCard(), profile: taste, recipient: nil, mission: mission)
        #expect(line.contains("Loose-leaf jasmine tea"))   // still anchored to the mission
        #expect(line.lowercased().contains("loose-leaf over bags"))  // and the fitting leaning is named
    }

    // MARK: Seed-voice + gift framing preservation (must survive the mission threading)

    @Test("A seed-voiced rationale (echoes a leaning) is kept verbatim even with a mission")
    func seedVoiceKeptVerbatim() {
        // Our own copy — it echoes the "merino" leaning, so it reads as Crumb and must survive.
        let seed = Self.teaCard("A quiet nod to merino over synthetic — warm even wet.")
        let line = curator.rationale(for: seed, profile: Self.defaultTaste, recipient: nil, mission: Self.teaMission)
        #expect(line == seed.rationale)   // verbatim, mission or not
    }

    @Test("Gift framing is preserved: seed voice keeps the \"A gift for Mom.\" tag with a mission")
    func giftSeedVoiceTagged() {
        let seed = Self.teaCard("A quiet nod to merino over synthetic.")
        let line = curator.rationale(for: seed, profile: Self.defaultTaste, recipient: Self.mom, mission: Self.teaMission)
        #expect(line == "\(seed.rationale) A gift for Mom.")
    }

    @Test("Gift floor reads on-topic, addresses Mom, and drops an off-topic default leaning (#33)")
    func giftReadsOnTopic() {
        let line = curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste,
                                     recipient: Self.mom, mission: Self.teaMission)
        #expect(line.lowercased().contains("premium"))   // #58: concrete quality signal, on-topic
        #expect(line.contains("Mom"))                    // still a gift for Mom
        #expect(!line.lowercased().contains("merino"))   // no off-topic leaning
    }

    @Test("Gift floor keeps the \"Mom's lean toward …\" framing when the leaning fits the mission")
    func giftKeepsFittingLeaningFramed() {
        let mission = ShoppingTask(
            id: "goal.loose-leaf-jasmine", title: "Loose-leaf jasmine tea", subtitle: "Bright + floral",
            plan: ["Tea"], curatorNote: "", accentHex: 0, candidateIDs: [], searchQueries: ["tea"]
        )
        let taste = TasteProfile(vibe: [], leanings: ["Loose-leaf over bags"], budgetComfort: 0.5, signatureLine: "")
        let line = curator.rationale(for: Self.teaCard(), profile: taste, recipient: Self.mom, mission: mission)
        #expect(line.contains("Loose-leaf jasmine tea"))
        #expect(line.contains("Mom's lean toward loose-leaf over bags"))
    }

    // MARK: mission == nil reproduces today's mission-agnostic line, byte-for-byte

    @Test("mission == nil owner line is exactly today's leaning nod")
    func ownerNilMissionUnchanged() {
        let line = curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: nil, mission: nil)
        #expect(line == "A pick that fits your lean toward merino over synthetic.")
        // …and the mission-free overload routes to the same string.
        #expect(line == curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: nil))
    }

    @Test("mission == nil gift line is exactly today's gift leaning nod")
    func giftNilMissionUnchanged() {
        let line = curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: Self.mom, mission: nil)
        #expect(line == "A gift that fits Mom's lean toward merino over synthetic.")
        #expect(line == curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: Self.mom))
    }

    // MARK: The live curator forwards the mission to the floor (the #33 regression that shipped)

    @Test("AppleFoundationCurator's floor threads the mission (no-model path is the app's live floor)")
    func appleFoundationForwardsMission() {
        // The app wires `AppleFoundationCurator`; its no-model floor must reach RuleBasedCurator's
        // mission-aware line, not the protocol default that silently drops the mission. On the sim
        // this method is model-free (it's a pure delegate to `rule`), so it's deterministic here.
        let af = AppleFoundationCurator()
        let rule = RuleBasedCurator()
        let owner = af.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: nil, mission: Self.teaMission)
        #expect(owner == rule.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: nil, mission: Self.teaMission))
        #expect(owner.lowercased().contains("premium"))   // #58: concrete quality voice reaches the live floor
        #expect(!owner.lowercased().contains("merino"))
        // And the gift path too.
        let gift = af.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: Self.mom, mission: Self.teaMission)
        #expect(gift == rule.rationale(for: Self.teaCard(), profile: Self.defaultTaste, recipient: Self.mom, mission: Self.teaMission))
        #expect(gift.contains("Mom"))
        #expect(!gift.lowercased().contains("merino"))
    }

    @Test("An imperative mission title stays grammatical (quoted anchor), never off-topic")
    func imperativeMissionGrammatical() {
        // "Pack me for a rainy weekend hike" is a verb phrase — the quoted anchor keeps it readable.
        let line = curator.rationale(for: Self.teaCard(), profile: Self.defaultTaste,
                                     recipient: nil, mission: SeedData.hike)
        #expect(line.contains("Pack me for a rainy weekend hike"))
        // The default leanings' keywords don't appear in the hike title/subtitle, so none is named
        // — the point of this case is that the quoted anchor keeps a verb-phrase title well-formed.
        #expect(line == "A steady pick for \u{201C}Pack me for a rainy weekend hike\u{201D}.")
    }
}
