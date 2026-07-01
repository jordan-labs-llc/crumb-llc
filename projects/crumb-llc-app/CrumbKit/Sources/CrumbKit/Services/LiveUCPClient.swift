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
    /// A launch-time readiness ping that warms the scale-to-zero broker, retried until the container
    /// answers. `searchCatalog` awaits it, so the ~30s cold start is absorbed *here* — kicked at
    /// construction (app init), overlapping the seconds the user spends typing a goal and editing the
    /// plan — instead of stalling the user's first real query. `nil` when warming is off (the plain
    /// `init`, used by tests) so it stays a no-op there.
    private let readiness: Task<Void, Never>?

    /// - Parameter warmOnInit: when `true`, kick the readiness ping immediately (the app path). Off by
    ///   default so a test's stub-session client doesn't fire background network.
    public init(baseURL: URL, brokerKey: String? = nil, session: URLSession = .shared, warmOnInit: Bool = false) {
        self.baseURL = baseURL
        self.brokerKey = brokerKey
        self.session = session
        self.readiness = warmOnInit ? Self.startReadiness(baseURL: baseURL, session: session) : nil
    }

    /// Convenience init from a ``UCPConfig``; returns `nil` when no broker is configured.
    ///
    /// When no explicit `session` is passed it builds one with a longer request timeout than
    /// `URLSession.shared`'s 60s default is comfortable with for our purposes: the broker
    /// scales to zero, so the first request after idle can spend ~20s+ in a cold start. The
    /// bumped timeout keeps that first real query from being cut off, and the readiness ping
    /// (started here, at construction) warms the container while the user is still deciding.
    public init?(config: UCPConfig, session: URLSession? = nil) {
        guard let url = config.brokerBaseURL else { return nil }
        self.init(
            baseURL: url,
            brokerKey: config.brokerKey,
            session: session ?? Self.makeSession(),
            warmOnInit: true
        )
    }

    /// Pings the broker's cheap `.well-known/ucp` endpoint, retrying with a short backoff until the
    /// container answers (any HTTP status means it's up) or the attempts run out. Detached + utility
    /// priority so it never blocks launch; all errors are absorbed — a failed warm is no worse than
    /// not warming. Retrying is the fix for the old single-shot ping that a slow cold start could miss.
    static func startReadiness(baseURL: URL, session: URLSession) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let url = baseURL.appending(path: ".well-known/ucp")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                if let (_, response) = try? await session.data(for: request),
                   response is HTTPURLResponse {
                    return   // the container answered — it's warm
                }
                if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
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
        // Absorb the cold start into the launch-time warm: if the broker is still spinning up, wait
        // for the readiness ping (already in flight since app init) rather than racing it. Once warm
        // this returns instantly, so it only ever delays the very first query on a cold container.
        await readiness?.value
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

    /// Awaits the launch-time readiness ping (see ``startReadiness(baseURL:session:)``), which the
    /// `init?(config:)` path kicks at construction. Kept for the `RootView` warm-up hook: calling it
    /// just joins the in-flight warm rather than firing a second, un-retried GET. A no-op when warming
    /// is off (the plain `init`).
    public func warmUp() async {
        await readiness?.value
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
