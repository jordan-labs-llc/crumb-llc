import Testing
import Foundation
@testable import CrumbKit

@Suite("Mission shortlist")
struct MissionShortlistTests {

    private static func tea(
        _ id: String,
        _ name: String,
        _ price: Decimal,
        shop: String = "harney",
        rating: Double = 4.5
    ) -> Product {
        Product(
            id: id,
            name: name,
            shop: Shop(id: shop, name: shop.capitalized),
            price: price,
            rating: rating,
            reviews: 100,
            rationale: "Because it suits you.",
            symbol: "leaf.fill",
            gradient: [0x27514A, 0x16332E],
            variants: [Variant(id: "\(id).v", title: "2 oz", price: price)]
        )
    }

    /// The exact ladder from the reported session, in the order it was shown.
    private static let reportedLadder = [
        tea("organic", "Organic Jasmine", 18),
        tea("dragon", "Dragon Pearl Jasmine", 28),
        tea("dragon-2", "Dragon Pearl Jasmine", 28),                        // the duplicate
        tea("supreme", "Dragon Pearl Jasmine Supreme", 32, shop: "redblossom"),
        tea("pearls", "Jasmine Pearls", 43.99, shop: "goldenmoon"),
        tea("rishi", "Jasmine", 58, shop: "rishi"),
    ]

    // MARK: Shape

    @Test("A shortlist is never more than three, and always leads with the winner")
    func neverMoreThanThree() throws {
        let shortlist = try #require(MissionShortlist.choose(from: Self.reportedLadder))
        #expect(shortlist.all.count <= 3)
        #expect(shortlist.all.first?.id == shortlist.winner.id)
        #expect(shortlist.winner.id == "organic", "the curator's top rank is the answer")
    }

    @Test("The foils bracket the winner on price")
    func foilsBracketTheWinner() throws {
        let candidates = [
            Self.tea("mid", "Middle", 28),
            Self.tea("low", "Low", 15),
            Self.tea("high", "High", 45),
        ]
        let shortlist = try #require(MissionShortlist.choose(from: candidates))
        #expect(shortlist.winner.id == "mid")
        #expect(shortlist.cheaper?.id == "low")
        #expect(shortlist.nicer?.id == "high")
    }

    // MARK: The floors

    /// The reported view showed "Dragon Pearl Jasmine · Harney · $28.00" twice.
    @Test("The same product from the same shop is never offered twice")
    func duplicatesAreDropped() throws {
        let shortlist = try #require(MissionShortlist.choose(from: Self.reportedLadder))
        let identities = shortlist.all.map(MissionShortlist.identity(of:))
        #expect(Set(identities).count == identities.count)
        let ids = shortlist.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Duplicate identity folds across punctuation and case")
    func identityFolds() {
        #expect(MissionShortlist.identity(of: Self.tea("a", "Dragon Pearl Jasmine", 28))
            == MissionShortlist.identity(of: Self.tea("b", "dragon-pearl  JASMINE", 28)))
        // Different shops are different offers, even for the same title.
        #expect(MissionShortlist.identity(of: Self.tea("a", "Jasmine", 28, shop: "harney"))
            != MissionShortlist.identity(of: Self.tea("b", "Jasmine", 28, shop: "rishi")))
    }

    @Test("A foil a few cents away is not a choice, and is not offered")
    func indistinctFoilsAreDropped() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [
            Self.tea("mid", "Middle", 28),
            Self.tea("near", "Nearly the same", 28.50, shop: "other"),
        ]))
        #expect(shortlist.cheaper == nil)
        #expect(shortlist.nicer == nil)
        #expect(shortlist.isSolo)
    }

    /// Crumb has shipped a $1,450 tea into a cart. An outlier is not a "nicer" option.
    @Test("A wildly-priced outlier is never shown as the nicer option")
    func outliersAreRejected() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [
            Self.tea("mid", "Middle", 28),
            Self.tea("absurd", "Reserve Vintage", 1450, shop: "other"),
        ]))
        #expect(shortlist.nicer == nil, "$1,450 is not a peer of $28")
    }

    @Test("A merely-expensive option is still a legitimate foil")
    func nonOutliersSurvive() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [
            Self.tea("mid", "Middle", 28),
            Self.tea("nice", "Nicer", 95, shop: "other"),
        ]))
        #expect(shortlist.nicer?.id == "nice", "95 is under 4x of 28 and is a real upgrade")
    }

    @Test("The cheaper foil is the least expensive real option, not the nearest")
    func cheaperIsTheFloor() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [
            Self.tea("mid", "Middle", 40),
            Self.tea("near", "Near", 34, shop: "a"),
            Self.tea("far", "Far", 12, shop: "b"),
        ]))
        #expect(shortlist.cheaper?.id == "far")
    }

    @Test("The nicer foil is the nearest upgrade, not the most expensive")
    func nicerIsTheNearestUpgrade() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [
            Self.tea("mid", "Middle", 28),
            Self.tea("near", "Near", 40, shop: "a"),
            Self.tea("far", "Far", 90, shop: "b"),
        ]))
        #expect(shortlist.nicer?.id == "near")
    }

    // MARK: Degenerate input

    @Test("No candidates yields no shortlist")
    func emptyYieldsNil() {
        #expect(MissionShortlist.choose(from: []) == nil)
    }

    @Test("One candidate is still an answer")
    func singleCandidateIsSolo() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [Self.tea("only", "Only", 28)]))
        #expect(shortlist.isSolo)
        #expect(shortlist.all.count == 1)
        #expect(shortlist.foils.isEmpty)
    }

    @Test("A free winner does not crash the outlier guard")
    func zeroPricedWinner() throws {
        let shortlist = try #require(MissionShortlist.choose(from: [
            Self.tea("free", "Free sample", 0),
            Self.tea("paid", "Paid", 28, shop: "other"),
        ]))
        #expect(shortlist.winner.id == "free")
        #expect(shortlist.nicer?.id == "paid")
    }

    @Test("Choosing is deterministic")
    func deterministic() {
        #expect(MissionShortlist.choose(from: Self.reportedLadder)
            == MissionShortlist.choose(from: Self.reportedLadder))
    }

    /// The comparison block validates at 2...4 products, so a shortlist must always fit it.
    @Test("A shortlist always fits the comparison block's contract")
    func fitsTheComparisonContract() throws {
        let shortlist = try #require(MissionShortlist.choose(from: Self.reportedLadder))
        #expect((1...3).contains(shortlist.all.count))
        if !shortlist.isSolo { #expect((2...4).contains(shortlist.all.count)) }
    }
}
