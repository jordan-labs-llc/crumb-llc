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
    /// True when the goal names ONE specific thing to buy (`premium jasmine tea`, `a cast iron
    /// skillet`) rather than outfitting a space or activity that needs several complementary parts
    /// (`set up my pour-over corner`). The planner already computes this to decide plan altitude
    /// (see ``AppleFoundationMissionPlanner``); surfacing it here lets the journey frame a direct
    /// search as a shortlist-and-compare flow instead of kit assembly (#56). Defaults `false`, so
    /// the seed missions (all multi-part kits) keep the kit framing untouched.
    public let isSingleItem: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        plan: [String],
        curatorNote: String,
        accentHex: UInt32,
        candidateIDs: [Product.ID],
        searchQueries: [String] = [],
        isSingleItem: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.plan = plan
        self.curatorNote = curatorNote
        self.accentHex = accentHex
        self.candidateIDs = candidateIDs
        self.searchQueries = searchQueries
        self.isSingleItem = isSingleItem
    }

    /// A copy with `isSingleItem` overridden — used by the planner degrade path and the DEBUG
    /// screenshot hook to flip framing without rebuilding every field by hand.
    public func settingSingleItem(_ value: Bool) -> ShoppingTask {
        ShoppingTask(
            id: id, title: title, subtitle: subtitle, plan: plan, curatorNote: curatorNote,
            accentHex: accentHex, candidateIDs: candidateIDs, searchQueries: searchQueries,
            isSingleItem: value
        )
    }

    // Custom decode so snapshots persisted before `isSingleItem` existed (History / recents) still
    // decode — the missing key reads as `false`. Encoding stays synthesized over these keys.
    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, plan, curatorNote, accentHex, candidateIDs, searchQueries, isSingleItem
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decode(String.self, forKey: .subtitle)
        plan = try c.decode([String].self, forKey: .plan)
        curatorNote = try c.decode(String.self, forKey: .curatorNote)
        accentHex = try c.decode(UInt32.self, forKey: .accentHex)
        candidateIDs = try c.decode([Product.ID].self, forKey: .candidateIDs)
        searchQueries = try c.decodeIfPresent([String].self, forKey: .searchQueries) ?? []
        isSingleItem = try c.decodeIfPresent(Bool.self, forKey: .isSingleItem) ?? false
    }
}
