import Foundation

/// The seam onto Shopify's Universal Commerce Protocol (UCP) Catalog APIs.
///
/// Method names mirror the real UCP operations so a `LiveUCPClient` is a drop-in later.
///
/// ## GA-vs-handoff reality (why this shape)
/// - **Global Catalog search is GA** — needs only an API key. (`searchCatalog`/`product`)
/// - **Native in-agent checkout requires Shopify opt-in** per merchant, so it is *not*
///   assumed here.
/// - **Universal Cart is early access** — `assembleCart` models it, but the default,
///   always-available path is a **per-shop handoff** (`checkoutHandoff`) that opens each
///   merchant's own secure checkout via its `continue_url`.
///
/// Everything in this scaffold is backed by ``MockUCPClient`` — no network, no keys.
public protocol UCPClient: Sendable {
    /// Maps to UCP `search_catalog` over the Global Catalog.
    func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product]

    /// Maps to UCP `get_product`.
    func product(id: Product.ID) async throws -> Product

    /// Assembles a (cross-merchant) cart. Real impl: Universal Cart (early access).
    func assembleCart(_ items: [KitItem]) async throws -> Cart

    /// Returns the per-shop checkout handoff URL (UCP `continue_url`).
    func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL
}

/// Errors surfaced by ``UCPClient`` implementations.
public enum UCPError: Error, Sendable, Equatable {
    /// No product matched the requested id.
    case productNotFound(Product.ID)
    /// The shop has no items in the cart, so no handoff can be produced.
    case emptyShopHandoff(Shop.ID)
}
