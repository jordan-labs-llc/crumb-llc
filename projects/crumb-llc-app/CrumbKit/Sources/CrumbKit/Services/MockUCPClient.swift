import Foundation

/// In-memory ``UCPClient`` backed by ``SeedData`` — no network, no API key.
///
/// `searchCatalog` supports two query styles:
/// 1. A **mission keyword** (e.g. `"hike"`, `"coffee"`, `"desk"`, or words from a
///    mission's title) returns that mission's candidate products in curated order.
/// 2. Otherwise a simple **keyword filter** across product name, rationale, and shop.
public struct MockUCPClient: UCPClient {

    /// Optional artificial latency, in nanoseconds, to exercise async UI states.
    /// Defaults to `0` so tests stay fast and deterministic.
    public let simulatedLatency: UInt64

    public init(simulatedLatency: UInt64 = 0) {
        self.simulatedLatency = simulatedLatency
    }

    public func searchCatalog(
        _ query: String,
        placements: [Placement] = [.organic]
    ) async throws -> [Product] {
        try await tick()

        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SeedData.products }

        // 1. Mission match — id or any word from the mission title.
        if let mission = SeedData.missions.first(where: { mission in
            mission.id == needle
                || mission.title.lowercased().contains(needle)
                || needle.split(separator: " ").contains { word in
                    mission.title.lowercased().contains(word)
                }
        }) {
            let candidates = candidates(for: mission)
            return filtered(candidates, placements: placements)
        }

        // 2. Keyword filter across the whole catalog.
        let hits = SeedData.products.filter { product in
            product.name.lowercased().contains(needle)
                || product.rationale.lowercased().contains(needle)
                || product.shop.name.lowercased().contains(needle)
        }
        return filtered(hits, placements: placements)
    }

    public func product(id: Product.ID) async throws -> Product {
        try await tick()
        guard let product = SeedData.productsByID[id] else {
            throw UCPError.productNotFound(id)
        }
        return product
    }

    public func assembleCart(_ items: [KitItem]) async throws -> Cart {
        try await tick()
        return Cart(items: items)
    }

    public func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        try await tick()
        let shopItems = cart.items(for: shop)
        guard !shopItems.isEmpty else {
            throw UCPError.emptyShopHandoff(shop.id)
        }
        // Mock `continue_url`: a deterministic, non-routable handoff target. A live client
        // would return the merchant's real secure-checkout URL from the catalog response.
        let ids = shopItems.map(\.variant.id).joined(separator: ",")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "checkout.example.invalid"
        components.path = "/\(shop.id)"
        components.queryItems = [URLQueryItem(name: "items", value: ids)]
        guard let url = components.url else {
            throw UCPError.emptyShopHandoff(shop.id)
        }
        return url
    }

    // MARK: - Helpers

    /// The candidate products for a mission, in the mission's curated order.
    public func candidates(for task: ShoppingTask) -> [Product] {
        task.candidateIDs.compactMap { SeedData.productsByID[$0] }
    }

    /// In the mock, all seed results are organic. When the caller does not request
    /// `.organic`, return nothing (there are no promoted seed items yet).
    private func filtered(_ products: [Product], placements: [Placement]) -> [Product] {
        placements.contains(.organic) ? products : []
    }

    private func tick() async throws {
        guard simulatedLatency > 0 else { return }
        try await Task.sleep(nanoseconds: simulatedLatency)
    }
}
