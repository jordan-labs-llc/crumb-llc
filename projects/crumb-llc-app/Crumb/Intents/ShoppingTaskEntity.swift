import AppIntents
import CrumbKit

/// A mission, modeled as an `AppEntity` so Siri / Shortcuts can reference it.
struct ShoppingTaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mission"
    static let defaultQuery = ShoppingTaskQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ task: ShoppingTask) {
        self.id = task.id
        self.title = task.title
    }
}

/// Resolves ``ShoppingTaskEntity`` values from the seed missions.
struct ShoppingTaskQuery: EntityQuery {
    func entities(for identifiers: [ShoppingTaskEntity.ID]) async throws -> [ShoppingTaskEntity] {
        SeedData.missions
            .filter { identifiers.contains($0.id) }
            .map(ShoppingTaskEntity.init)
    }

    func suggestedEntities() async throws -> [ShoppingTaskEntity] {
        SeedData.missions.map(ShoppingTaskEntity.init)
    }
}
