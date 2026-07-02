import Foundation

/// A cross-merchant cart assembled from the user's kit. Subtotal is derived from the
/// chosen variants. In a live integration this maps to UCP's Universal Cart (early
/// access); here it is computed locally with no network.
public struct Cart: Sendable, Codable, Hashable {
    public let items: [KitItem]

    public init(items: [KitItem]) {
        self.items = items
    }

    /// Sum of the chosen variant prices.
    public var subtotal: Decimal {
        items.reduce(0) { $0 + $1.variant.price }
    }

    /// The lowest and highest variant price in the cart, or `nil` when empty. The single-product
    /// compare-and-buy cart (#60) shows this range instead of a subtotal — summing alternatives the
    /// user will pick *one* of would be misleading.
    public var priceRange: (min: Decimal, max: Decimal)? {
        guard let first = items.first?.variant.price else { return nil }
        return items.dropFirst().reduce((min: first, max: first)) { acc, item in
            (min: Swift.min(acc.min, item.variant.price), max: Swift.max(acc.max, item.variant.price))
        }
    }

    /// The distinct shops represented in the cart, in first-seen order. Checkout hands
    /// off per shop, so the UI groups by these.
    public var shops: [Shop] {
        var seen = Set<Shop.ID>()
        var ordered: [Shop] = []
        for item in items where seen.insert(item.product.shop.id).inserted {
            ordered.append(item.product.shop)
        }
        return ordered
    }

    /// Items belonging to a given shop.
    public func items(for shop: Shop) -> [KitItem] {
        items.filter { $0.product.shop.id == shop.id }
    }

    /// Subtotal for a given shop.
    public func subtotal(for shop: Shop) -> Decimal {
        items(for: shop).reduce(0) { $0 + $1.variant.price }
    }
}
