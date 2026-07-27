import Testing
import Foundation
@testable import CrumbKit

/// `ShopNameHygiene.display(for:)` is the shared, pure, offline-safe policy that turns a seller
/// domain into a shop-shaped display name. The catalog carries no seller name, so the domain is all
/// there is: strip the plumbing, re-space what honestly decomposes, and leave the rest alone.
@Suite("Shop name hygiene")
struct ShopNameHygieneTests {

    // MARK: - Stripping the plumbing

    @Test("A bare seller domain loses its TLD and reads as a name")
    func tldStripped() {
        #expect(ShopNameHygiene.display(for: "harney.com") == "Harney")
        #expect(ShopNameHygiene.display(for: "smithey.com") == "Smithey")
        #expect(ShopNameHygiene.display(for: "ooni.com") == "Ooni")
    }

    @Test("Subdomains are dropped, whatever the merchant called them")
    func subdomainsDropped() {
        #expect(ShopNameHygiene.display(for: "www.harney.com") == "Harney")
        #expect(ShopNameHygiene.display(for: "shop.bombas.com") == "Bombas")
        #expect(ShopNameHygiene.display(for: "eu.twinings.com") == "Twinings")
    }

    @Test("A Shopify-hosted shop keeps its own label, not `myshopify`")
    func myshopifyIsAPublicSuffix() {
        #expect(ShopNameHygiene.display(for: "northbound.myshopify.com") == "Northbound")
        #expect(ShopNameHygiene.display(for: "field-flask.myshopify.com") == "Field Flask")
    }

    @Test("A compound public suffix doesn't eat the brand label")
    func compoundSuffixes() {
        #expect(ShopNameHygiene.display(for: "twinings.co.uk") == "Twinings")
        #expect(ShopNameHygiene.display(for: "startfitness.co.uk") == "Start Fitness")
        #expect(ShopNameHygiene.display(for: "www.secondearth.com.au") == "Second Earth")
    }

    @Test("Case, a full URL, and a port are all tolerated, not just the bare host")
    func toleratesUnexpectedShapes() {
        #expect(ShopNameHygiene.display(for: "HARNEY.COM") == "Harney")
        #expect(ShopNameHygiene.display(for: "https://www.harney.com/products/hot-cinnamon") == "Harney")
        #expect(ShopNameHygiene.display(for: "harney.com:443") == "Harney")
    }

    // MARK: - Re-spacing

    @Test("A squashed multi-word domain is re-spaced into words")
    func squashedWordsSplit() {
        // The motivating case: a bare `goldenmoontea` reads as a typo under a product name.
        #expect(ShopNameHygiene.display(for: "goldenmoontea.com") == "Golden Moon Tea")
        #expect(ShopNameHygiene.display(for: "www.freshroastedcoffee.com") == "Fresh Roasted Coffee")
        #expect(ShopNameHygiene.display(for: "www.universallacrosse.com") == "Universal Lacrosse")
    }

    @Test("An unknown brand token keeps its known category tail")
    func brandTokenPlusKnownTail() {
        #expect(ShopNameHygiene.display(for: "yolohayoga.com") == "Yoloha Yoga")
        #expect(ShopNameHygiene.display(for: "www.lemsshoes.com") == "Lems Shoes")
        #expect(ShopNameHygiene.display(for: "www.lodgecastiron.com") == "Lodge Cast Iron")
    }

    @Test("A greedy dead end backtracks to the split that actually covers the label")
    func splitBacktracks() {
        // `team` strands `akers`, so the search must back up to `tea` + `makers`.
        #expect(ShopNameHygiene.display(for: "www.theteamakers.co.uk") == "The Tea Makers")
    }

    @Test("Hyphens and underscores are word boundaries")
    func separatorsSplit() {
        #expect(ShopNameHygiene.display(for: "www.rishi-tea.com") == "Rishi Tea")
        #expect(ShopNameHygiene.display(for: "www.hario-usa.com") == "Hario USA")
        #expect(ShopNameHygiene.display(for: "field_notes.com") == "Field Notes")
    }

    // MARK: - Conservatism

    @Test("A brand that only half-decomposes is left whole, never mis-split")
    func neverMisSplits() {
        // `north` is a known word but `bound` is not, so the cover fails and the label stands —
        // "North Bound" would be a wrong name, and a wrong name is worse than a squashed one.
        #expect(ShopNameHygiene.display(for: "northbound.com") == "Northbound")
        #expect(ShopNameHygiene.display(for: "twinings.com") == "Twinings")
        #expect(ShopNameHygiene.display(for: "angelinos.com") == "Angelinos")
        #expect(ShopNameHygiene.display(for: "magnolia.com") == "Magnolia")
    }

    @Test("A short label is a brand, not a sentence, so it is never split")
    func shortLabelsNeverSplit() {
        #expect(ShopNameHygiene.display(for: "teas.com") == "Teas")
        #expect(ShopNameHygiene.display(for: "bathe.com") == "Bathe")
    }

    @Test("An all-consonant label reads as an initialism and stays upper")
    func acronymsStayUpper() {
        #expect(ShopNameHygiene.display(for: "stx.com") == "STX")
        #expect(ShopNameHygiene.display(for: "www.vsslgear.com") == "VSSL Gear")
        #expect(ShopNameHygiene.display(for: "originusa.com") == "Origin USA")
    }

    @Test("A domain with nothing renderable yields nil, so the caller can fall back")
    func nothingRenderableIsNil() {
        #expect(ShopNameHygiene.display(for: nil) == nil)
        #expect(ShopNameHygiene.display(for: "") == nil)
        #expect(ShopNameHygiene.display(for: "   ") == nil)
        #expect(ShopNameHygiene.display(for: ".") == nil)
    }

    @Test("Every output is free of domain plumbing — no dots, no scheme, no www")
    func outputCarriesNoDomainPlumbing() throws {
        for domain in Self.liveSellerDomains {
            let name = try #require(ShopNameHygiene.display(for: domain))
            #expect(!name.contains("."), "\(domain) → \(name)")
            #expect(!name.lowercased().hasPrefix("www"), "\(domain) → \(name)")
            #expect(name.first?.isLowercase != true, "\(domain) → \(name)")
        }
    }

    // MARK: - The live corpus

    /// Seller domains observed on the live Shopify Global Catalog (2026-07-27, 70 products over 8
    /// queries) — the real distribution this policy has to survive, pinned so a vocabulary change
    /// can't silently mangle a shop we actually sell from.
    ///
    /// A handful stay squashed on purpose (`Drakewaterfowl`, `Gobros`, `Sportstop`): their labels
    /// don't decompose into known words, and the policy prefers an honest squash to a guess.
    static let liveSellerDomains = [
        "alternativebrewing.com.au", "angelinos.com", "darntough.com", "dragongirltea.com",
        "fieldcompany.com", "kalitausa.com", "madameflavour.com", "magnolia.com", "ooni.com",
        "originusa.com", "pureover.com", "shop.7kft.co", "shop.bombas.com", "shop.manflowyoga.com",
        "signaturelacrosse.com", "smithey.com", "startfitness.co.uk", "stx.com",
        "thelatestdrop.com", "twinings.co.uk", "unboundmerino.com", "www.drakewaterfowl.com",
        "www.espressoparts.com", "www.everydayyoga.com", "www.freshroastedcoffee.com",
        "www.gobros.com", "www.hario-usa.com", "www.harney.com", "www.lemsshoes.com",
        "www.lodgecastiron.com", "www.rishi-tea.com", "www.scoriaworld.com",
        "www.secondearth.com.au", "www.sportstop.com", "www.theteamakers.co.uk",
        "www.universallacrosse.com", "www.vsslgear.com", "yolohayoga.com",
    ]

    @Test("The live seller-domain corpus renders as shop names", arguments: zip(
        liveSellerDomains,
        [
            "Alternative Brewing", "Angelinos", "Darn Tough", "Dragon Girl Tea",
            "Field Company", "Kalita USA", "Madame Flavour", "Magnolia", "Ooni",
            "Origin USA", "Pureover", "7kft", "Bombas", "Man Flow Yoga",
            "Signature Lacrosse", "Smithey", "Start Fitness", "STX",
            "The Latest Drop", "Twinings", "Unbound Merino", "Drakewaterfowl",
            "Espresso Parts", "Everyday Yoga", "Fresh Roasted Coffee",
            "Gobros", "Hario USA", "Harney", "Lems Shoes",
            "Lodge Cast Iron", "Rishi Tea", "Scoria World",
            "Second Earth", "Sportstop", "The Tea Makers",
            "Universal Lacrosse", "VSSL Gear", "Yoloha Yoga",
        ]
    ))
    func liveCorpusRenders(domain: String, expected: String) {
        #expect(ShopNameHygiene.display(for: domain) == expected)
    }
}
