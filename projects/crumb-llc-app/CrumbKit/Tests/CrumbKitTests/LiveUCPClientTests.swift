import Testing
import Foundation
@testable import CrumbKit

/// Stubs URLSession so the live client's transport + DTO mapping can be tested offline.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URL) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url ?? URL(string: "https://invalid.invalid")!
        let (status, data) = Self.responder?(url) ?? (500, Data())
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("LiveUCPClient broker contract", .serialized)
struct LiveUCPClientTests {

    private func makeClient() -> LiveUCPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return LiveUCPClient(
            baseURL: URL(string: "https://broker.test")!,
            brokerKey: "fn-key",
            session: session
        )
    }

    @Test("search maps broker JSON to domain products")
    func searchMaps() async throws {
        let json = """
        { "ucpVersion": "2026-04-08", "products": [
          { "id": "gid://shopify/p/abc", "title": "Organic Crewneck",
            "priceMin": { "amount": 8900, "currency": "USD" },
            "sellerDomain": "northbound.myshopify.com",
            "imageURL": "https://cdn.shopify.com/p/abc.jpg",
            "buyURL": "https://northbound.myshopify.com/cart/c/xyz",
            "variantId": "gid://shopify/v/1" } ] }
        """
        StubURLProtocol.responder = { _ in (200, Data(json.utf8)) }

        let products = try await makeClient().searchCatalog("crewneck", placements: [.organic])

        #expect(products.count == 1)
        let product = try #require(products.first)
        #expect(product.name == "Organic Crewneck")
        #expect(product.price == Decimal(89))             // 8900 minor units → 89
        #expect(product.shop.name == "northbound")        // domain prettified
        #expect(product.imageURL?.absoluteString == "https://cdn.shopify.com/p/abc.jpg")
        #expect(product.defaultVariant.checkoutURL?.absoluteString
            == "https://northbound.myshopify.com/cart/c/xyz")
    }

    @Test("object-shaped description ({plain}) decodes tolerantly into rationale")
    func tolerantDescription() async throws {
        // The live catalog returns text fields as `{ "plain": "…" }` objects; the client
        // must not choke on that (a typeMismatch would blank the whole search).
        let json = """
        { "products": [
          { "id": "p", "title": "Cielo Rain Jacket",
            "description": { "plain": "Eco-friendly rain jacket." },
            "priceMin": { "amount": 5800, "currency": "USD" },
            "sellerDomain": "www.cotopaxi.com",
            "imageURL": "https://cdn.shopify.com/x.png",
            "buyURL": "https://www.cotopaxi.com/products/cielo?variant=1",
            "variantId": "gid://shopify/ProductVariant/1" } ] }
        """
        StubURLProtocol.responder = { _ in (200, Data(json.utf8)) }

        let products = try await makeClient().searchCatalog("rain jacket", placements: [.organic])
        let product = try #require(products.first)
        #expect(product.name == "Cielo Rain Jacket")
        #expect(product.rationale == "Eco-friendly rain jacket.")
        #expect(product.shop.name == "cotopaxi.com")   // `www.` stripped, TLD kept
        #expect(product.defaultVariant.checkoutURL?.absoluteString
            == "https://www.cotopaxi.com/products/cielo?variant=1")
    }

    @Test("product endpoint maps a single product")
    func productMaps() async throws {
        let json = """
        { "product": { "id": "p1", "title": "Kettle",
          "priceMin": { "amount": 12900, "currency": "USD" },
          "sellerDomain": "field-flask.myshopify.com" } }
        """
        StubURLProtocol.responder = { _ in (200, Data(json.utf8)) }

        let product = try await makeClient().product(id: "p1")
        #expect(product.name == "Kettle")
        #expect(product.price == Decimal(129))
    }

    @Test("missing product throws productNotFound")
    func missingProductThrows() async throws {
        StubURLProtocol.responder = { _ in (200, Data(#"{ "product": null }"#.utf8)) }
        await #expect(throws: UCPError.self) {
            _ = try await makeClient().product(id: "nope")
        }
    }

    @Test("checkout handoff uses the variant continue_url")
    func handoffUsesVariantURL() async throws {
        let url = URL(string: "https://shop.example/cart/c/1")!
        let shop = Shop(id: "shop.example", name: "Shop")
        let product = Product(
            id: "p", name: "Thing", shop: shop, price: 10, rating: 0, reviews: 0,
            rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "v", title: "Standard", price: 10, checkoutURL: url)]
        )
        let cart = Cart(items: [KitItem(product: product)])

        let handoff = try await makeClient().checkoutHandoff(for: shop, in: cart)
        #expect(handoff == url)
    }

    @Test("handoff falls back to the merchant storefront when no variant continue_url")
    func handoffFallsBackToStorefront() async throws {
        // Variant carries no checkoutURL, but the shop id is a real domain.
        let shop = Shop(id: "www.cotopaxi.com", name: "cotopaxi")
        let product = Product(
            id: "p", name: "Jacket", shop: shop, price: 58, rating: 0, reviews: 0,
            rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "v", title: "Standard", price: 58, checkoutURL: nil)]
        )
        let cart = Cart(items: [KitItem(product: product)])

        let handoff = try await makeClient().checkoutHandoff(for: shop, in: cart)
        #expect(handoff.absoluteString == "https://www.cotopaxi.com")
    }

    @Test("handoff throws when there is neither a continue_url nor a known domain")
    func handoffThrowsWithoutTarget() async throws {
        let shop = Shop(id: "unknown", name: "Shop")
        let product = Product(
            id: "p", name: "Jacket", shop: shop, price: 58, rating: 0, reviews: 0,
            rationale: "", symbol: "bag", gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "v", title: "Standard", price: 58, checkoutURL: nil)]
        )
        let cart = Cart(items: [KitItem(product: product)])

        await #expect(throws: UCPError.self) {
            _ = try await makeClient().checkoutHandoff(for: shop, in: cart)
        }
    }
}
