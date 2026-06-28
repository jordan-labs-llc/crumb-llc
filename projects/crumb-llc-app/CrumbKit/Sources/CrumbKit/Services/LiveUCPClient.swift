import Foundation

/// Talks to the **Crumb broker** (`crumb-llc-api`) over HTTPS. The broker holds the
/// Shopify UCP credentials and calls the UCP Global Catalog server-side; this client only
/// knows the broker's base URL (+ an optional broker access key).
///
/// v1 covers discovery (`search_catalog` / `get_product`). Cart assembly is computed
/// locally (the broker is stateless), and per-shop checkout uses the catalog's
/// `continue_url` (carried on the variant) as the handoff target.
public struct LiveUCPClient: UCPClient {
    private let baseURL: URL
    private let brokerKey: String?
    private let session: URLSession

    public init(baseURL: URL, brokerKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.brokerKey = brokerKey
        self.session = session
    }

    /// Convenience init from a ``UCPConfig``; returns `nil` when no broker is configured.
    ///
    /// When no explicit `session` is passed it builds one with a longer request timeout than
    /// `URLSession.shared`'s 60s default is comfortable with for our purposes: the broker
    /// scales to zero, so the first request after idle can spend ~20s+ in a cold start. The
    /// bumped timeout keeps that first real query from being cut off (paired with the
    /// launch-time ``warmUp()`` ping, which usually warms the container first).
    public init?(config: UCPConfig, session: URLSession? = nil) {
        guard let url = config.brokerBaseURL else { return nil }
        self.init(
            baseURL: url,
            brokerKey: config.brokerKey,
            session: session ?? Self.makeSession()
        )
    }

    /// A session tuned for the broker's cold-start latency.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = coldStartTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    /// Per-request timeout, sized for a scale-to-zero cold start (first hit can take 20s+).
    static let coldStartTimeout: TimeInterval = 30

    // MARK: UCPClient

    public func searchCatalog(
        _ query: String,
        placements: [Placement]
    ) async throws -> [Product] {
        let response: BrokerSearchResponse = try await post(
            "catalog/search",
            body: ["query": query]
        )
        return response.products.map { $0.toProduct() }
    }

    public func product(id: Product.ID) async throws -> Product {
        let response: BrokerProductResponse = try await post(
            "catalog/product",
            body: ["productId": id]
        )
        guard let product = response.product else {
            throw UCPError.productNotFound(id)
        }
        return product.toProduct()
    }

    public func assembleCart(_ items: [KitItem]) async throws -> Cart {
        // The broker is stateless and does not assemble carts in v1; compute locally.
        Cart(items: items)
    }

    public func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        // Prefer the per-shop `continue_url` carried on a chosen variant (the real,
        // variant-specific secure-checkout link from the catalog).
        if let url = cart.items(for: shop).compactMap({ $0.variant.checkoutURL }).first {
            return url
        }
        // Fallback: when no variant carries a continue_url but we at least know the
        // merchant's domain, hand off to its storefront homepage so checkout still does
        // something honest. (`shop.id` is the seller domain in live results.)
        if let url = Self.storefrontURL(for: shop) {
            return url
        }
        throw UCPError.emptyShopHandoff(shop.id)
    }

    /// The merchant's storefront homepage, when `shop.id` looks like a real domain.
    /// Returns `nil` for the synthesized `"unknown"` shop (no seller domain in the data).
    static func storefrontURL(for shop: Shop) -> URL? {
        let domain = shop.id
        guard domain != "unknown", domain.contains(".") else { return nil }
        return URL(string: "https://\(domain)")
    }

    /// Wakes the (scale-to-zero) broker with a cheap, cacheable GET so the first real query
    /// usually lands warm. Fire-and-forget: the result is discarded and every error is
    /// swallowed — a failed warm-up is no worse than not warming up at all.
    public func warmUp() async {
        let url = baseURL.appending(path: ".well-known/ucp")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        _ = try? await session.data(for: request)
    }

    // MARK: Transport

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let brokerKey {
            request.setValue(brokerKey, forHTTPHeaderField: "x-broker-key")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveUCPClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LiveUCPClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveUCPClientError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LiveUCPClientError.decoding(error)
        }
    }
}

/// Errors specific to the broker transport (distinct from ``UCPError``).
public enum LiveUCPClientError: Error, Sendable {
    case transport(Error)
    case invalidResponse
    case httpStatus(Int)
    case decoding(Error)
}

// MARK: - Broker DTOs (mirror crumb-llc-api's normalized JSON)

private struct BrokerSearchResponse: Decodable {
    let products: [BrokerProduct]
    let ucpVersion: String?
}

private struct BrokerProductResponse: Decodable {
    let product: BrokerProduct?
}

private struct BrokerMoney: Decodable {
    let amount: Int?       // integer minor units (e.g. cents)
    let currency: String?
}

private struct BrokerOption: Decodable {
    let name: String?
    let values: [String]?
}

/// A UCP text field that may arrive as a bare string *or* a `{ "plain": "…" }` object.
///
/// The broker flattens these to plain strings, but decoding tolerantly here means a future
/// shape change (or talking to an older broker) degrades to `nil` instead of failing the
/// whole product — one bad field must never blank an entire search.
private struct FlexibleText: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let object = try? container.decode(Plain.self) {
            value = object.plain
        } else {
            value = nil
        }
    }

    private struct Plain: Decodable { let plain: String? }
}

private struct BrokerProduct: Decodable {
    let id: String?
    let title: String?
    let description: FlexibleText?
    let imageURL: String?
    let priceMin: BrokerMoney?
    let priceMax: BrokerMoney?
    let sellerDomain: String?
    let options: [BrokerOption]?
    let buyURL: String?
    let variantId: String?
}

private extension BrokerProduct {
    /// Map a catalog product onto the app's domain model, synthesizing the
    /// presentation-only fields (symbol/gradient/rating) the catalog doesn't carry —
    /// curation fills these in properly downstream.
    func toProduct() -> Product {
        let identifier = id ?? UUID().uuidString
        let amount = priceMin?.amount ?? 0
        let price = Decimal(amount) / 100
        let shop = Shop(
            id: sellerDomain ?? "unknown",
            name: prettyShopName(sellerDomain) ?? "Shop"
        )
        let variant = Variant(
            id: variantId ?? "\(identifier).default",
            title: "Standard",
            price: price,
            checkoutURL: buyURL.flatMap(URL.init(string:))
        )
        return Product(
            id: identifier,
            name: title ?? "Untitled",
            shop: shop,
            price: price,
            rating: 0,
            reviews: 0,
            rationale: description?.value ?? "",
            symbol: "bag",
            gradient: gradient(for: identifier),
            // Real product photo when the catalog carries one; the card falls back to the
            // synthesized gradient + symbol when this is nil or fails to load.
            imageURL: imageURL.flatMap(URL.init(string:)),
            variants: [variant]
        )
    }

    /// Deterministically pick a card gradient so results look varied but stable.
    func gradient(for id: String) -> [UInt32] {
        let palettes = [
            SeedData.Gradient.pine,
            SeedData.Gradient.earth,
            SeedData.Gradient.stone,
            SeedData.Gradient.ochre,
        ]
        let index = abs(id.hashValue) % palettes.count
        return palettes[index]
    }

    func prettyShopName(_ domain: String?) -> String? {
        guard let domain else { return nil }
        return domain
            .replacingOccurrences(of: ".myshopify.com", with: "")
            .replacingOccurrences(of: "www.", with: "")
    }
}
