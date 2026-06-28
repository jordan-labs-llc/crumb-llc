import Foundation

/// A purchasable variant of a ``Product`` (size, color, bundle, …).
///
/// `checkoutURL` is the per-shop UCP handoff target (the `continue_url` returned by the
/// catalog) — `nil` in seed data since the mock performs no real checkout.
public struct Variant: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let price: Decimal
    public let checkoutURL: URL?

    public init(id: String, title: String, price: Decimal, checkoutURL: URL? = nil) {
        self.id = id
        self.title = title
        self.price = price
        self.checkoutURL = checkoutURL
    }
}
