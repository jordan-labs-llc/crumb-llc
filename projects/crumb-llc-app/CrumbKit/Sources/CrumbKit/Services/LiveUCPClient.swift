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
    public init?(config: UCPConfig, session: URLSession = .shared) {
        guard let url = config.brokerBaseURL else { return nil }
        self.init(baseURL: url, brokerKey: config.brokerKey, session: session)
    }

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
        // Use the per-shop `continue_url` carried on a chosen variant.
        let handoff = cart.items(for: shop)
            .compactMap { $0.variant.checkoutURL }
            .first
        guard let url = handoff else {
            throw UCPError.emptyShopHandoff(shop.id)
        }
        return url
    }

    // MARK: Transport

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let brokerKey {
            request.setValue(brokerKey, forHTTPHeaderField: "x-functions-key")
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

private struct BrokerProduct: Decodable {
    let id: String?
    let title: String?
    let description: String?
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
            rationale: description ?? "",
            symbol: "bag",
            gradient: gradient(for: identifier),
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
