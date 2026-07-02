import Testing
import Foundation
@testable import CrumbKit

/// Coverage for the category-aware premium-tea ranking + rationale (#58): for `premium jasmine tea`
/// the deck must lead with a credible specialty pick and explain concrete quality signals, and must
/// not promote an obvious budget/sample/sachet listing above a stronger premium option. Pure and
/// deterministic — no model, so this is exactly what the sim/CI floor produces.
@Suite("Premium tea curation (#58)")
struct PremiumTeaCurationTests {

    private let curator = RuleBasedCurator()
    private let taste = SeedData.defaultTasteProfile

    private static let mission = ShoppingTask(
        id: "goal.premium-jasmine-tea", title: "Premium jasmine tea", subtitle: "A mission for you",
        plan: ["Loose-leaf jasmine tea"], curatorNote: "", accentHex: 0, candidateIDs: [],
        searchQueries: ["premium jasmine tea"]
    )

    private static func card(
        id: String, name: String, domain: String, price: Decimal, blurb: String, variant: String = "Standard"
    ) -> Product {
        Product(
            id: id, name: name, shop: Shop(id: domain, name: domain), price: price, rating: 0, reviews: 0,
            rationale: blurb, symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).v", title: variant, price: price, checkoutURL: nil)]
        )
    }

    // The fixture the issue calls for: a Rishi-style premium, a generic jasmine, a cheap sachet pack.
    private static let rishi = card(
        id: "rishi", name: "Jasmine", domain: "rishi-tea.com", price: 58,
        blurb: "Loose-leaf jasmine green tea, scented with fresh jasmine blossoms."
    )
    private static let generic = card(
        id: "generic", name: "Jasmine Tea", domain: "thefoalyard.co.uk", price: 17,
        blurb: "Jasmine tea."
    )
    private static let sachet = card(
        id: "sachet", name: "Silk Dragon Jasmine", domain: "davidstea.com", price: 6.15,
        blurb: "12 sachets of jasmine green tea.", variant: "12 sachets"
    )
    private static let sample = card(
        id: "sample", name: "Jasmine Tea Sampler", domain: "genericshop.com", price: 5,
        blurb: "A trial sampler of jasmine tea."
    )

    @Test("The premium specialty pick ranks first; the cheap sachet never outranks it")
    func premiumRanksFirst() {
        let ranked = curator.rank([Self.sachet, Self.generic, Self.rishi, Self.sample], for: taste, mission: Self.mission)
        #expect(ranked.first?.id == "rishi")
        // The budget sachet/sample sit behind both the premium and the plain-but-plausible generic.
        let order = ranked.map(\.id)
        #expect(order.firstIndex(of: "rishi")! < order.firstIndex(of: "sachet")!)
        #expect(order.firstIndex(of: "generic")! < order.firstIndex(of: "sachet")!)
        #expect(order.firstIndex(of: "generic")! < order.firstIndex(of: "sample")!)
    }

    @Test("Top 3 for a premium jasmine query includes at least one clearly premium/specialty result")
    func topThreeHasAPremium() {
        let ranked = curator.rank([Self.sachet, Self.sample, Self.generic, Self.rishi], for: taste, mission: Self.mission)
        let top3 = ranked.prefix(3)
        #expect(top3.contains { TeaCuration.grade($0) == .premium || TeaCuration.isSpecialtyTeaMerchant($0) })
    }

    @Test("Top-card rationale names concrete tea-quality signals, not just the mission title")
    func premiumRationaleIsConcrete() {
        let line = curator.rationale(for: Self.rishi, profile: taste, recipient: nil, mission: Self.mission)
        #expect(line.lowercased().contains("loose-leaf"))
        #expect(line.lowercased().contains("specialty tea merchant"))
        #expect(line != "A steady pick for \u{201C}Premium jasmine tea\u{201D}.")   // not the old generic floor
    }

    @Test("Card copy distinguishes premium / sachet / sample")
    func copyDistinguishesGrades() {
        let sachetLine = curator.rationale(for: Self.sachet, profile: taste, recipient: nil, mission: Self.mission)
        #expect(sachetLine.lowercased().contains("sachets"))
        #expect(sachetLine.lowercased().contains("less premium"))

        let sampleLine = curator.rationale(for: Self.sample, profile: taste, recipient: nil, mission: Self.mission)
        #expect(sampleLine.lowercased().contains("sample"))

        let genericLine = curator.rationale(for: Self.generic, profile: taste, recipient: nil, mission: Self.mission)
        #expect(genericLine.lowercased().contains("leaf grade") || genericLine.lowercased().contains("origin"))
    }

    @Test("Grade classification reads title/blurb/size honestly")
    func gradeClassification() {
        #expect(TeaCuration.grade(Self.rishi) == .premium)
        #expect(TeaCuration.grade(Self.generic) == .generic)
        #expect(TeaCuration.grade(Self.sachet) == .sachet)
        #expect(TeaCuration.grade(Self.sample) == .sample)
    }

    @Test("A non-tea mission is untouched — the tea layer contributes nothing")
    func nonTeaMissionUnaffected() {
        #expect(TeaCuration.scoreAdjustment(Self.rishi, mission: SeedData.hike) == 0)
        // Ranking a non-tea mission matches the mission-agnostic sort exactly.
        let base = curator.rank([Self.rishi, Self.generic], for: taste, mission: nil)
        let hike = curator.rank([Self.rishi, Self.generic], for: taste, mission: SeedData.hike)
        #expect(base.map(\.id) == hike.map(\.id))
    }
}
