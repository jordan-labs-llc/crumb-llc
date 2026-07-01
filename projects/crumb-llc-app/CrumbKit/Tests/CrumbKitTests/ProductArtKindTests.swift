import Testing
import Foundation
@testable import CrumbKit

/// `Product.artKind` is the shared, pure "which art to show" decision behind the card, the
/// cart line, and the kit-tray thumbnails — a real photo when the catalog carries one, else
/// the synthesized gradient+glyph fallback (seed data, or a live product with no image).
@Suite("Product art kind")
struct ProductArtKindTests {

    private func product(imageURL: URL?) -> Product {
        Product(
            id: "p1",
            name: "Jasmine Tea",
            shop: Shop(id: "s1", name: "Rishi"),
            price: 17,
            rating: 0,
            reviews: 0,
            rationale: "A pick that fits your lean.",
            symbol: "leaf.fill",
            gradient: [0x2E5D4B, 0x1B3A2F],
            imageURL: imageURL,
            variants: [Variant(id: "v1", title: "2oz", price: 17)]
        )
    }

    @Test("A product with a photo uses that photo")
    func usesPhotoWhenImagePresent() {
        let url = URL(string: "https://cdn.example.com/jasmine.jpg")!
        #expect(product(imageURL: url).artKind == .photo(url))
    }

    @Test("A product without a photo falls back to the synthesized art")
    func fallsBackWhenNoImage() {
        #expect(product(imageURL: nil).artKind == .synthesized)
    }

    @Test("Seed products carry no photo, so they render the synthesized art")
    func seedProductsAreSynthesized() {
        for seed in SeedData.products {
            #expect(seed.artKind == .synthesized)
        }
    }
}
