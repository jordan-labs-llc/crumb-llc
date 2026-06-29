import Foundation

/// A saved, reusable person you shop *for* — the heart of the "shop for someone else" feature.
///
/// Each recipient carries their **own** ``TasteProfile``, so a gift mission can curate fully to
/// them (the planner, curator, refinement, and recap all read this taste instead of the owner's).
/// "Yourself" is **not** a recipient: it's the owner ``TasteProfile`` managed by the taste editor,
/// represented as the absence of an active recipient (`nil`). A recipient is intentional and
/// long-lived — added, edited, and deleted by hand — so the roster is bounded but never silently
/// evicted (unlike ``RecentMissionsStore``). Per-device, not synced.
public struct Recipient: Identifiable, Hashable, Sendable, Codable {
    /// Stable identity (a `UUID` string), minted once when the person is added.
    public let id: String
    public var name: String
    /// How they relate to you, in your own words ("my dad", "partner", "a coworker"). Free-text and
    /// optional so anything fits; the gift voice uses it verbatim. `nil` / blank ⇒ name only.
    public var relationship: String?
    /// Their taste — the lens a gift mission curates through. Captured from free text via
    /// ``TasteExtractor`` and editable in the same editor the owner uses.
    public var taste: TasteProfile
    /// The person's accent color (packed RGB), tinting their cards/chips like a mission's accent.
    public var accentHex: UInt32
    /// When they were added — drives the roster's newest-first ordering (injected clock in tests).
    public let createdAt: Date

    public init(
        id: String,
        name: String,
        relationship: String? = nil,
        taste: TasteProfile,
        accentHex: UInt32,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.relationship = relationship
        self.taste = taste
        self.accentHex = accentHex
        self.createdAt = createdAt
    }

    /// A lean snapshot of this person for embedding on a saved ``HistoryEntry`` and for passing as
    /// gift context into the voice seams (the curator + recap don't need the whole profile here).
    public var ref: RecipientRef { RecipientRef(self) }
}

/// A lean, immutable snapshot of a ``Recipient`` — the identity + display facets, without the full
/// taste profile. Two jobs, both wanting the same small bundle:
///
/// 1. **History attribution.** Embedded on a ``HistoryEntry`` so a saved mission records *who* it
///    was for, tinted by their accent, forever — even if the person is later edited or deleted
///    (consistent with History's offline-receipt philosophy: the entry is a faithful snapshot, not
///    a live reference). `nil` on an entry means "for Yourself".
/// 2. **Gift voice context.** Passed into ``CuratorEngine`` and ``RecapWriter`` so the rationale and
///    recap can address the gift by name/relationship ("a gift for Mom").
public struct RecipientRef: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let relationship: String?
    public let accentHex: UInt32

    public init(id: String, name: String, relationship: String? = nil, accentHex: UInt32) {
        self.id = id
        self.name = name
        self.relationship = relationship
        self.accentHex = accentHex
    }

    /// Projects a full ``Recipient`` to its lean reference.
    public init(_ recipient: Recipient) {
        self.init(
            id: recipient.id,
            name: recipient.name,
            relationship: recipient.relationship,
            accentHex: recipient.accentHex
        )
    }

    /// The relationship trimmed to a non-empty value, or `nil` — so blanks never reach the voice.
    public var trimmedRelationship: String? {
        relationship?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
}

extension String {
    /// `self` when it has non-whitespace content, else `nil`. Kept here so CrumbKit's pure helpers
    /// can fold blank optional strings without importing the app's `trimmed` extension.
    var nonEmpty: String? { isEmpty ? nil : self }
}
