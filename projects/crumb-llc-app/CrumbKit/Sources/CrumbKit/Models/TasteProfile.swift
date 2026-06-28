import Foundation

/// A lightweight model of the user's taste, used by ``CuratorEngine`` to rank products
/// and phrase rationales. `budgetComfort` is `0…1` (0 = thrifty, 1 = splurge-happy).
public struct TasteProfile: Sendable, Codable, Hashable {
    public var vibe: [String]
    public var leanings: [String]
    public var budgetComfort: Double
    public var signatureLine: String

    public init(
        vibe: [String],
        leanings: [String],
        budgetComfort: Double,
        signatureLine: String
    ) {
        self.vibe = vibe
        self.leanings = leanings
        self.budgetComfort = budgetComfort
        self.signatureLine = signatureLine
    }

    /// A cleaned-up copy suitable for persisting: chips trimmed, blanks dropped, deduped
    /// case-insensitively (first spelling wins); `budgetComfort` clamped to `0…1`; the
    /// signature trimmed. Editing UIs run this on Save so a stray space or duplicate chip
    /// never reaches the store or the curator.
    public var normalized: TasteProfile {
        TasteProfile(
            vibe: Self.tidy(vibe),
            leanings: Self.tidy(leanings),
            budgetComfort: min(1, max(0, budgetComfort)),
            signatureLine: signatureLine.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func tidy(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            out.append(value)
        }
        return out
    }
}
