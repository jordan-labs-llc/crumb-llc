import Foundation

/// Deterministic, offline ``RecapWriter`` — the default for the scaffold and the only writer that
/// runs on the simulator/CI (where the on-device model is unavailable).
///
/// It does not try to be lyrical: it derives a short kit tag from the goal's key words and a warm,
/// **honest** line from the facts it has (how many pieces, across how many shops, and the user's
/// top leaning) — never inventing qualities about the products. The richer, voiced recap is the job
/// of ``AppleFoundationRecapWriter`` when a model tier is up; this is the dependable floor it
/// degrades to (and the shared home for the pure helpers both writers use).
public struct RuleBasedRecapWriter: RecapWriter {

    public init() {}

    public func writeRecap(
        goal: String,
        plan: [String],
        items: [RecapFact],
        profile: TasteProfile,
        recipient: RecipientRef?
    ) async -> WrittenRecap {
        // `reason: nil` — a *chosen* default here (mock scaffold / sim), so the UI stays quiet.
        Self.recap(goal: goal, plan: plan, items: items, profile: profile, recipient: recipient, reason: nil)
    }

    /// The deterministic recap, with an explicit fallback `reason` so the AI writer can reuse this
    /// floor and still report *why* it degraded. Pure (no model, no I/O) — the unit-tested guarantee
    /// behind the seam. Public so the app can seed a brand-new history entry with a recap
    /// *synchronously* (the row must be complete the instant it's saved), then upgrade it with the
    /// on-device writer without ever leaving the entry half-written. When `recipient` is set the line
    /// is gift-aware ("… — a gift for Mom.") — the deterministic guarantee the sim/CI actually renders.
    public static func recap(
        goal: String,
        plan: [String],
        items: [RecapFact],
        profile: TasteProfile,
        recipient: RecipientRef? = nil,
        reason: RecapTier.Fallback?
    ) -> WrittenRecap {
        WrittenRecap(
            tag: tag(forGoal: goal),
            line: line(items: items, profile: profile, recipient: recipient),
            tier: .ruleBased(reason)
        )
    }

    // MARK: - Shared pure helpers (used by AppleFoundationRecapWriter too)

    /// A short, crafted kit title from the goal's key words: drop leading filler ("pack me for a"),
    /// title-case the first few content words, and append "kit" — e.g. "Pack me for a rainy weekend
    /// hike" → "Rainy weekend hike kit". Capped so a paragraph-long goal can't blow out the card.
    public static func tag(forGoal goal: String) -> String {
        let words = goal
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .drop { fillerLeads.contains($0) }

        let kept = Array(words.prefix(maxTagWords))
        guard !kept.isEmpty else { return "Your kit" }

        let titled = kept
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return titled + " kit"
    }

    /// A warm, honest record line from the facts on hand: piece count, shop count, and the user's
    /// top leaning when they have one. No invented product qualities — those are the model's to add.
    /// When `recipient` is set the line closes with "— a gift for <Name>." so the deterministic floor
    /// (what the sim/CI renders) honestly reads as a gift; `recipient == nil` is the owner kit.
    public static func line(items: [RecapFact], profile: TasteProfile, recipient: RecipientRef? = nil) -> String {
        let n = items.count
        let giftSuffix = recipient.map { " — a gift for \($0.name)" } ?? ""
        guard n > 0 else { return "A kit, saved for later\(giftSuffix)." }

        let pieces = "\(n) \(n == 1 ? "piece" : "pieces")"
        let shopCount = Set(items.map(\.shop)).count
        let shops = "\(shopCount) \(shopCount == 1 ? "shop" : "shops")"

        let lean = profile.leanings.first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : ", leaning \($0.lowercased())" }
            ?? ""

        return "\(pieces) from \(shops)\(lean)\(giftSuffix)."
    }

    /// How many content words the tag may carry before it stops reading as a title.
    static let maxTagWords = 4

    /// Leading words that carry no kit identity — stripped so the tag starts on the real subject.
    private static let fillerLeads: Set<String> = [
        "pack", "me", "for", "a", "an", "the", "set", "up", "my", "make", "get", "got",
        "help", "find", "i", "want", "need", "to", "some", "of", "with", "build", "give",
    ]
}
