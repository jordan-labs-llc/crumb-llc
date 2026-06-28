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
}
