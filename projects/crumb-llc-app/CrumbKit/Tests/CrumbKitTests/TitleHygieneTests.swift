import Testing
import Foundation
@testable import CrumbKit

/// `TitleHygiene.display(for:)` is the shared, pure, offline-safe policy that turns a raw catalog
/// title into a legible display name: it surfaces the Latin portion of a mixed-script title, leaves
/// a single-script title alone, and always keeps *some* honest text rather than blanking a title.
@Suite("Title hygiene")
struct TitleHygieneTests {

    @Test("A mixed Latin + CJK title surfaces the Latin portion, CJK dropped")
    func mixedScriptSurfacesLatin() {
        let raw = "Imperial Choice Premium Green Tea 御茗 高級綠茶 100g"
        #expect(TitleHygiene.display(for: raw) == "Imperial Choice Premium Green Tea 100g")
    }

    @Test("A single-script Latin title is returned unchanged")
    func latinTitleUnchanged() {
        #expect(TitleHygiene.display(for: "Rishi Jasmine Green Tea") == "Rishi Jasmine Green Tea")
    }

    @Test("An all-CJK title has no Latin portion, so it falls back to the raw title")
    func allCJKFallsBackToRaw() {
        let raw = "御茗 高級綠茶"
        #expect(TitleHygiene.display(for: raw) == raw)
    }

    @Test("A trailing CJK run leaves no stray separator on the surfaced Latin text")
    func trailingSeparatorTrimmed() {
        #expect(TitleHygiene.display(for: "Green Tea · 綠茶") == "Green Tea")
        #expect(TitleHygiene.display(for: "Green Tea - 綠茶 -") == "Green Tea")
    }

    @Test("A leading CJK run leaves no stray separator either")
    func leadingSeparatorTrimmed() {
        #expect(TitleHygiene.display(for: "綠茶 - Green Tea") == "Green Tea")
    }

    @Test("Interior whitespace stranded by a dropped CJK run is collapsed")
    func interiorWhitespaceCollapsed() {
        #expect(TitleHygiene.display(for: "Green 御茗 Tea") == "Green Tea")
    }

    @Test("Accented Latin (Latin-1 / Extended) is kept, not treated as foreign")
    func accentedLatinKept() {
        #expect(TitleHygiene.display(for: "Café Crème Brûlée") == "Café Crème Brûlée")
        // Vietnamese uses Latin Extended Additional — still Latin, still single-script.
        #expect(TitleHygiene.display(for: "Trà Xanh Đặc Biệt") == "Trà Xanh Đặc Biệt")
    }

    @Test("A non-Latin, non-CJK script (Cyrillic) with a Latin run surfaces the Latin run")
    func cyrillicMixedSurfacesLatin() {
        #expect(TitleHygiene.display(for: "Green Tea Зелёный чай") == "Green Tea")
    }

    @Test("An all-Cyrillic title falls back to raw (no Latin portion to surface)")
    func allCyrillicFallsBackToRaw() {
        let raw = "Зелёный чай"
        #expect(TitleHygiene.display(for: raw) == raw)
    }

    @Test("Digits, units, and ASCII punctuation are neutral and always kept")
    func neutralCharactersKept() {
        #expect(TitleHygiene.display(for: "Loose Leaf Tea (2oz) — 50% off") == "Loose Leaf Tea (2oz) — 50% off")
        // Digits/symbols surrounding a dropped CJK run survive on the Latin side.
        #expect(TitleHygiene.display(for: "Tea 綠茶 2oz") == "Tea 2oz")
    }

    @Test("Empty and whitespace-only inputs are safe and yield empty")
    func emptyAndWhitespaceSafe() {
        #expect(TitleHygiene.display(for: "") == "")
        #expect(TitleHygiene.display(for: "   \n\t ") == "")
    }

    @Test("Surrounding whitespace is trimmed even on an otherwise-unchanged Latin title")
    func surroundingWhitespaceTrimmed() {
        #expect(TitleHygiene.display(for: "  Jasmine Tea  ") == "Jasmine Tea")
    }

    @Test("Product.displayTitle routes through the same policy")
    func productDisplayTitleUsesPolicy() {
        let product = Product(
            id: "p1",
            name: "Imperial Choice Premium Green Tea 御茗 高級綠茶 100g",
            shop: Shop(id: "s1", name: "brooklane.shop"),
            price: 17,
            rating: 0,
            reviews: 0,
            rationale: "A steady pick.",
            symbol: "leaf.fill",
            gradient: [0x2E5D4B, 0x1B3A2F],
            imageURL: nil,
            variants: [Variant(id: "v1", title: "100g", price: 17)]
        )
        #expect(product.displayTitle == "Imperial Choice Premium Green Tea 100g")
    }
}
