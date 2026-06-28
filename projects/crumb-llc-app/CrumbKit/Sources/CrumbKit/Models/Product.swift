import Foundation

/// A product Crumb can propose for a mission.
///
/// `rationale` is the curator's "why this is you" voice copy (rendered in the serif
/// role by the UI). `symbol` is an SF Symbol placeholder for the art, and `gradient`
/// holds two packed-RGB hex stops used to render the card art.
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
        self.variants = variants
    }

    /// The default variant a swipe-accept adds to the kit (first listed).
    public var defaultVariant: Variant {
        variants.first ?? Variant(id: "\(id).default", title: name, price: price)
    }
}
