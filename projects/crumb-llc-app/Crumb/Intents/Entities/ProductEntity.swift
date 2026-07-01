import AppIntents
import CrumbKit

/// An onscreen product from the curated swipe deck, exposed to App Intents / Siri so the deck —
/// Crumb's signature interaction — becomes something the system can *see and act on*. A user
/// looking at the deck can say "add this to my kit", "skip it", or "why this one?" and Siri
/// resolves the visible ``ProductEntity`` (issue #41).
///
/// The entity carries flat display values (name, shop, price, rationale, symbol) so its
/// `displayRepresentation` needs no live model lookup; the id is the deck ``Product`` id, resolved
/// back to a live product by ``ProductEntityQuery`` when an intent runs. Deck products are
/// session-scoped (a mission's candidates), so an id that no longer resolves means the mission
/// moved on — the intents fail honestly rather than acting on a stale card.
struct ProductEntity: AppEntity, Identifiable {
    let id: Product.ID
    let name: String
    let shopName: String
    let priceText: String
    let rationale: String
    /// The product's SF Symbol — the synthesized art's glyph, reused as the entity's icon.
    let symbol: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Product")

    static let defaultQuery = ProductEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(shopName) · \(priceText)",
            image: .init(systemName: symbol)
        )
    }

    init(_ product: Product) {
        self.id = product.id
        self.name = product.name
        self.shopName = product.shop.name
        self.priceText = ProductEntity.priceFormatter.string(from: product.price as NSDecimalNumber)
            ?? "\(product.price)"
        self.rationale = product.rationale
        self.symbol = product.symbol
    }

    private static let priceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f
    }()
}

/// Resolves ``ProductEntity`` values against the live deck on the shared ``AppModel`` (registered
/// at launch in `CrumbApp`). `entities(for:)` looks ids up in the mission's full candidate pool so
/// an already-kitted card still resolves; `suggestedEntities()` offers the *visible* deck, which is
/// what the user is looking at when they invoke Siri onscreen.
struct ProductEntityQuery: EntityQuery {
    @Dependency var model: AppModel

    @MainActor
    func entities(for identifiers: [ProductEntity.ID]) async throws -> [ProductEntity] {
        identifiers.compactMap { model.sessionProduct(id: $0).map(ProductEntity.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProductEntity] {
        model.deckProducts.map(ProductEntity.init)
    }
}
