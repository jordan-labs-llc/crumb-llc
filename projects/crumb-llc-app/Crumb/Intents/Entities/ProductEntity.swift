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
    let id: String
    let productID: Product.ID
    let threadID: String?
    let interactionID: String?
    let interactionGeneration: Int?
    let subjectRevision: Int?
    let variantID: Variant.ID?
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

    init(_ product: Product, threadID: String? = nil, interaction: MissionPendingInteraction? = nil) {
        self.productID = product.id
        self.threadID = threadID
        self.interactionID = interaction?.id
        self.interactionGeneration = interaction?.interactionGeneration
        self.subjectRevision = interaction?.subjectRevision
        if case .product(_, let variantID) = interaction?.resolver { self.variantID = variantID }
        else { self.variantID = nil }
        self.id = Self.identity(
            productID: product.id, threadID: threadID, interactionID: interaction?.id,
            generation: interaction?.interactionGeneration, subjectRevision: interaction?.subjectRevision,
            variantID: self.variantID
        )
        self.name = product.name
        self.shopName = product.shop.name
        self.priceText = ProductEntity.priceFormatter.string(from: product.price as NSDecimalNumber)
            ?? "\(product.price)"
        self.rationale = product.rationale
        self.symbol = product.symbol
    }

    fileprivate init(_ product: Product, serializedIdentity: String) {
        let parts = serializedIdentity.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        productID = parts.first ?? product.id
        threadID = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        interactionID = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        interactionGeneration = parts.count > 3 ? Int(parts[3]) : nil
        subjectRevision = parts.count > 4 ? Int(parts[4]) : nil
        variantID = parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil
        id = serializedIdentity
        name = product.name
        shopName = product.shop.name
        priceText = ProductEntity.priceFormatter.string(from: product.price as NSDecimalNumber) ?? "\(product.price)"
        rationale = product.rationale
        symbol = product.symbol
    }

    private static func identity(
        productID: String, threadID: String?, interactionID: String?, generation: Int?,
        subjectRevision: Int?, variantID: String?
    ) -> String {
        [productID, threadID ?? "", interactionID ?? "", generation.map(String.init) ?? "",
         subjectRevision.map(String.init) ?? "", variantID ?? ""].joined(separator: "|")
    }

    fileprivate static func productID(from identity: String) -> String {
        identity.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? identity
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
        identifiers.compactMap { identity in
            let productID = ProductEntity.productID(from: identity)
            return model.sessionProduct(id: productID).map { ProductEntity($0, serializedIdentity: identity) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProductEntity] {
        model.deckProducts.map {
            ProductEntity($0, threadID: model.activeThreadID, interaction: model.activeThread?.pendingInteraction)
        }
    }
}
