import Foundation

/// A user "mission" — the task the curator works on (e.g. "Pack me for a rainy
/// weekend hike"). `candidateIDs` reference the products Crumb proposes for it.
///
/// `searchQueries` are the human-quality catalog queries this mission fans out to the
/// live broker (e.g. hike → "rain jacket", "hiking boots", "wool socks"). The
/// ``MockUCPClient`` ignores them and matches on `id`/`title`; the live path runs them
/// in parallel, dedupes by product id, and hands the union to the curator.
public struct ShoppingTask: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let plan: [String]
    public let curatorNote: String
    public let accentHex: UInt32
    public let candidateIDs: [Product.ID]
    public let searchQueries: [String]

    public init(
        id: String,
        title: String,
        subtitle: String,
        plan: [String],
        curatorNote: String,
        accentHex: UInt32,
        candidateIDs: [Product.ID],
        searchQueries: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.plan = plan
        self.curatorNote = curatorNote
        self.accentHex = accentHex
        self.candidateIDs = candidateIDs
        self.searchQueries = searchQueries
    }
}
