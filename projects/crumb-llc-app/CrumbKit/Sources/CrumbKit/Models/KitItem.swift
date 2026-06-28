import Foundation

/// One accepted item in the user's kit: a product plus the chosen variant.
/// Identity is the product id, so a product appears at most once in a kit.
public struct KitItem: Identifiable, Hashable, Sendable, Codable {
    public var id: String { product.id }
    public let product: Product
    public let variant: Variant

    public init(product: Product, variant: Variant) {
        self.product = product
        self.variant = variant
    }

    /// Convenience: accept a product at its default variant.
    public init(product: Product) {
        self.init(product: product, variant: product.defaultVariant)
    }
}
