import Foundation

/// A product Crumb can propose for a mission.
///
/// `rationale` is the curator's "why this is you" voice copy (rendered in the serif
/// role by the UI). `symbol` is an SF Symbol placeholder for the art, and `gradient`
/// holds two packed-RGB hex stops used to render the card art.
///
/// `imageURL` is a real product photo when one is available (live catalog results carry
/// it); when `nil` — seed data, or a live product with no image — the card falls back to
/// the synthesized `gradient` + `symbol` art.
public struct Product: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let shop: Shop
    public let price: Decimal
    public let rating: Double
    public let reviews: Int
    public let rationale: String
    public let symbol: String
    public let gradient: [UInt32]
    public let imageURL: URL?
    public let variants: [Variant]

    public init(
        id: String,
        name: String,
        shop: Shop,
        price: Decimal,
        rating: Double,
        reviews: Int,
        rationale: String,
        symbol: String,
        gradient: [UInt32],
        imageURL: URL? = nil,
        variants: [Variant]
    ) {
        self.id = id
        self.name = name
        self.shop = shop
        self.price = price
        self.rating = rating
        self.reviews = reviews
        self.rationale = rationale
        self.symbol = symbol
        self.gradient = gradient
        self.imageURL = imageURL
        self.variants = variants
    }

    /// The default variant a swipe-accept adds to the kit (first listed).
    public var defaultVariant: Variant {
        variants.first ?? Variant(id: "\(id).default", title: name, price: price)
    }

    /// A copy of this product with the curator's rationale swapped in. The curator engines
    /// use this to replace the raw merchant description with Crumb's voice copy — the card
    /// renders `rationale` directly, so rewriting it here is what puts the voice on screen.
    public func withRationale(_ rationale: String) -> Product {
        Product(
            id: id,
            name: name,
            shop: shop,
            price: price,
            rating: rating,
            reviews: reviews,
            rationale: rationale,
            symbol: symbol,
            gradient: gradient,
            imageURL: imageURL,
            variants: variants
        )
    }
}
