import Foundation

/// One snapshotted line in a saved mission's kit — a faithful, offline receipt of a single
/// product the user actually kept.
///
/// **Snapshot, not a reference.** Live UCP prices drift and `get_product` isn't exposed by the
/// GA catalog (it 502s), so a reference-based record often couldn't be rebuilt. We store exactly
/// what the kit held at save time — id, name, shop, the chosen variant's price/title, the image,
/// and the per-item buy URL — so History opens correctly forever, even offline. A snapshot's
/// `buyURL` may eventually 404; the re-shop surface surfaces that honestly rather than failing
/// silently (mirroring the checkout handoff's "no link" honesty).
public struct HistoryItem: Identifiable, Hashable, Sendable, Codable {
    /// The product id, also this line's identity (a product appears once per kit).
    public let productID: String
    public let name: String
    public let shop: Shop
    /// The chosen variant's price at save time.
    public let price: Decimal
    public let variantTitle: String
    /// The product photo, when the live catalog carried one (`nil` for seed/photo-less products).
    public let imageURL: URL?
    /// The per-item buy/handoff link snapshotted from the chosen variant (`variants[].url`).
    /// `nil` — or eventually a dead link — is surfaced honestly on re-shop, never silently.
    public let buyURL: URL?

    public var id: String { productID }

    public init(
        productID: String,
        name: String,
        shop: Shop,
        price: Decimal,
        variantTitle: String,
        imageURL: URL? = nil,
        buyURL: URL? = nil
    ) {
        self.productID = productID
        self.name = name
        self.shop = shop
        self.price = price
        self.variantTitle = variantTitle
        self.imageURL = imageURL
        self.buyURL = buyURL
    }

    /// Snapshots a live ``KitItem`` into a faithful receipt line at save time.
    public init(_ item: KitItem) {
        self.init(
            productID: item.product.id,
            name: item.product.name,
            shop: item.product.shop,
            price: item.variant.price,
            variantTitle: item.variant.title,
            imageURL: item.product.imageURL,
            buyURL: item.variant.checkoutURL
        )
    }
}

/// A persisted record of one completed shopping session: the goal + the editable plan the user
/// ran + the curator note + the **kit they actually assembled** (snapshotted ``HistoryItem``s) +
/// a curator-voice recap + a light outcome flag (did they hand off to a shop's checkout?).
///
/// This is the agent loop's memory. One entry per shopping session (per `enterPlan`); building a
/// kit for the same goal twice is two distinct entries. Skipped / proposed-but-unkept products are
/// not stored. Lean by design — it carries only what History needs to render an offline receipt,
/// re-shop from the snapshot, and re-plan the goal — so it never drags the live `Product` surface
/// (ratings, gradients, all variants) into the record.
public struct HistoryEntry: Identifiable, Hashable, Sendable, Codable {
    /// Stable per shopping session, so re-reaching the cart in one session updates the same entry
    /// rather than spawning near-duplicates from back-and-forth editing.
    public let id: String
    /// The original goal text, re-routed through the planner by "Plan this again".
    public let goal: String
    public let title: String
    public let subtitle: String
    /// The plan labels the user ran (the editable parts).
    public let plan: [String]
    /// The catalog queries behind the plan — kept for a faithful record of what was searched.
    public let searchQueries: [String]
    public let curatorNote: String
    public let accentHex: UInt32
    /// A short crafted 2–4 word card title ("Rainy-hike kit"), distinct from the raw goal.
    public let recapTag: String
    /// The curator-voice recap line ("quiet, waterproof, built to last"), rendered in serif.
    public let recapLine: String
    /// The kept items, snapshotted at save time.
    public let items: [HistoryItem]
    /// Who this kit was for, when it was a gift — a lean snapshot of the recipient at save time
    /// (consistent with History's offline-receipt philosophy: a faithful record, not a live
    /// reference, so it survives the person being edited or deleted). `nil` means "for Yourself"
    /// (the owner) — which is also how every pre-gift-feature row decodes.
    public let recipient: RecipientRef?
    /// `true` once the user opened a real checkout link for this kit (outcome flag).
    public let handedOff: Bool
    /// When the kit was first assembled (drives timeline grouping + ordering).
    public let createdAt: Date

    public init(
        id: String,
        goal: String,
        title: String,
        subtitle: String,
        plan: [String],
        searchQueries: [String],
        curatorNote: String,
        accentHex: UInt32,
        recapTag: String,
        recapLine: String,
        items: [HistoryItem],
        recipient: RecipientRef? = nil,
        handedOff: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.goal = goal
        self.title = title
        self.subtitle = subtitle
        self.plan = plan
        self.searchQueries = searchQueries
        self.curatorNote = curatorNote
        self.accentHex = accentHex
        self.recapTag = recapTag
        self.recapLine = recapLine
        self.items = items
        self.recipient = recipient
        self.handedOff = handedOff
        self.createdAt = createdAt
    }

    // MARK: Derived (the snapshot is immutable, so these never drift from a stored copy)

    public var itemCount: Int { items.count }

    /// Sum of the kept variants' prices.
    public var subtotal: Decimal { items.reduce(0) { $0 + $1.price } }

    /// The distinct shops in the kit, in first-seen order (re-shop hands off per shop).
    public var shops: [Shop] {
        var seen = Set<Shop.ID>()
        var ordered: [Shop] = []
        for item in items where seen.insert(item.shop.id).inserted {
            ordered.append(item.shop)
        }
        return ordered
    }

    public var shopCount: Int { shops.count }

    /// Items belonging to a given shop.
    public func items(for shop: Shop) -> [HistoryItem] {
        items.filter { $0.shop.id == shop.id }
    }

    /// Subtotal for a given shop.
    public func subtotal(for shop: Shop) -> Decimal {
        items(for: shop).reduce(0) { $0 + $1.price }
    }

    /// An immutable copy with the outcome flag flipped (the handoff-followed update).
    public func withHandedOff(_ value: Bool) -> HistoryEntry {
        HistoryEntry(
            id: id, goal: goal, title: title, subtitle: subtitle, plan: plan,
            searchQueries: searchQueries, curatorNote: curatorNote, accentHex: accentHex,
            recapTag: recapTag, recapLine: recapLine, items: items, recipient: recipient,
            handedOff: value, createdAt: createdAt
        )
    }
}

/// The aggregate "since you started" stat line over a user's whole history — the delight header
/// on the timeline ("N kits · M items · K shops · since <month>"). Pure: derived entirely from
/// the entries, so it's deterministic and unit-testable.
public struct HistoryStats: Sendable, Equatable {
    public let kitCount: Int
    public let itemCount: Int
    public let shopCount: Int
    /// The earliest entry's date, for the "since <month>" tail. `nil` when empty.
    public let since: Date?

    public init(entries: [HistoryEntry]) {
        kitCount = entries.count
        itemCount = entries.reduce(0) { $0 + $1.itemCount }
        var shops = Set<Shop.ID>()
        for entry in entries {
            for item in entry.items { shops.insert(item.shop.id) }
        }
        shopCount = shops.count
        since = entries.map(\.createdAt).min()
    }

    public var isEmpty: Bool { kitCount == 0 }

    /// Round-number kit counts worth a subtle, tasteful ochre flourish — never gamey, just a
    /// quiet "nice round number" at the milestones a careful shopper would actually notice.
    public static let milestones: Set<Int> = [5, 10, 25, 50]

    /// `true` when the kit count has just landed on a milestone, so the header can mark it softly.
    public var isMilestone: Bool { Self.milestones.contains(kitCount) }
}

/// A time bucket on the history timeline. Three coarse, human buckets — not exact dates — so the
/// record reads like a story ("earlier this week"), not a ledger.
public enum HistoryBucket: String, Sendable, CaseIterable {
    case today = "Today"
    case thisWeek = "This week"
    case earlier = "Earlier"
}

/// One rendered section of the timeline: a bucket and its entries (most-recent-first).
public struct HistorySection: Identifiable, Sendable, Equatable {
    public let bucket: HistoryBucket
    public let entries: [HistoryEntry]

    public var id: String { bucket.rawValue }

    public init(bucket: HistoryBucket, entries: [HistoryEntry]) {
        self.bucket = bucket
        self.entries = entries
    }
}

/// A History timeline filter by who a kit was for — the chip row at the top of the timeline.
/// `.all` shows everything; `.yourself` shows owner kits (no recipient); `.person(id)` shows a
/// single saved person's kits. Pure + `Hashable` so it drives a `@State`/`Picker` cleanly.
public enum HistoryRecipientFilter: Hashable, Sendable {
    case all
    case yourself
    case person(String)

    /// Whether `entry` passes this filter.
    public func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .yourself: return entry.recipient == nil
        case let .person(id): return entry.recipient?.id == id
        }
    }
}

/// One filter chip on the History timeline — a filter plus how to render it (label + optional
/// accent for tinting). Pure value so the facet set is deterministic and unit-testable.
public struct HistoryRecipientFacet: Identifiable, Sendable, Equatable {
    public let filter: HistoryRecipientFilter
    public let label: String
    /// The tint for this chip (the person's accent, or the owner accent for You). `nil` for All.
    public let accentHex: UInt32?

    public init(filter: HistoryRecipientFilter, label: String, accentHex: UInt32?) {
        self.filter = filter
        self.label = label
        self.accentHex = accentHex
    }

    public var id: String {
        switch filter {
        case .all: return "all"
        case .yourself: return "yourself"
        case let .person(id): return "person-\(id)"
        }
    }
}

/// Pure helpers for the History per-recipient filter — deriving the chips present in a history and
/// applying a chosen filter. Kept here next to the timeline grouping; both are unit-tested.
public enum HistoryFacets {
    /// The filter chips a history warrants: always **All**; **You** when at least one owner kit
    /// (no recipient) exists; and one chip per distinct recipient in first-seen order, labeled by
    /// name and tinted by their accent. A history with no gifts yet yields just `[All, You]` (the
    /// UI can choose to hide the row until there's more than one real facet).
    public static func facets(_ entries: [HistoryEntry], ownerAccentHex: UInt32) -> [HistoryRecipientFacet] {
        var out: [HistoryRecipientFacet] = [HistoryRecipientFacet(filter: .all, label: "All", accentHex: nil)]
        if entries.contains(where: { $0.recipient == nil }) {
            out.append(HistoryRecipientFacet(filter: .yourself, label: "You", accentHex: ownerAccentHex))
        }
        var seen = Set<String>()
        for entry in entries {
            guard let recipient = entry.recipient, seen.insert(recipient.id).inserted else { continue }
            out.append(HistoryRecipientFacet(
                filter: .person(recipient.id), label: recipient.name, accentHex: recipient.accentHex
            ))
        }
        return out
    }

    /// Entries passing `filter`, preserving the input's recency order.
    public static func apply(_ filter: HistoryRecipientFilter, to entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.filter(filter.matches)
    }
}

/// Pure timeline grouping. Splits entries (already most-recent-first) into Today / This week /
/// Earlier relative to an injected `now`, so grouping + ordering are deterministic and testable
/// (the codebase avoids wall-clock in test-reachable logic — the view passes `Date()`, tests pass
/// a fixed date). Empty buckets are omitted, and each section keeps the input's recency order.
public enum HistoryTimeline {
    /// Groups `entries` into sections. `now` and `calendar` are injected so day/week boundaries
    /// are exact in tests. "This week" is the seven days before today (today excluded); anything
    /// older is "Earlier".
    public static func sections(
        _ entries: [HistoryEntry],
        now: Date,
        calendar: Calendar = .current
    ) -> [HistorySection] {
        let startOfToday = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        var buckets: [HistoryBucket: [HistoryEntry]] = [:]
        for entry in entries {
            let bucket: HistoryBucket
            if entry.createdAt >= startOfToday {
                bucket = .today
            } else if entry.createdAt >= weekStart {
                bucket = .thisWeek
            } else {
                bucket = .earlier
            }
            buckets[bucket, default: []].append(entry)
        }

        // Stable, human order; drop empty buckets.
        return HistoryBucket.allCases.compactMap { bucket in
            guard let rows = buckets[bucket], !rows.isEmpty else { return nil }
            return HistorySection(bucket: bucket, entries: rows)
        }
    }
}
