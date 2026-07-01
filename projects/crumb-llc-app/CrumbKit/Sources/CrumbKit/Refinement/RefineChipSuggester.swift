import Foundation

/// A single quick-refinement chip on the Curate screen: a tappable shortcut for a common
/// "talk back to the curator" line. Each chip carries the exact `refinementText` a tap submits —
/// the same words a user could have typed — so the chip path and the free-text path run through
/// one ``RefinementInterpreter``. `id` is a stable slug used for the SwiftUI `ForEach` and the
/// `refineChip.<id>` accessibility identifier.
public struct RefineChip: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let refinementText: String

    public init(id: String, label: String, refinementText: String) {
        self.id = id
        self.label = label
        self.refinementText = refinementText
    }

    /// A stable, a11y-safe slug for a chip label ("Caffeine-free" → "caffeine-free"). Used as the
    /// identifier for model-suggested chips, whose labels aren't known ahead of time.
    public static func slug(_ label: String) -> String {
        let lowered = label.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        // Collapse runs of separators and trim them off the ends.
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "chip" : collapsed
    }
}

/// The quick-refinement-chip seam: turns the current mission into the row of chips shown above the
/// kit tray on the Curate screen. The fourth on-device twin of ``CuratorEngine`` /
/// ``MissionPlanner`` / ``RefinementInterpreter``: the deterministic ``RuleBasedRefineChipSuggester``
/// is the offline floor (the only tier that renders on the simulator/CI and in headless
/// screenshots), and ``AppleFoundationRefineChipSuggester`` reads the mission with the on-device
/// model when one is up, always degrading to that floor.
///
/// The chips exist to make the refinement bar *fit the mission*: "Warmer" and "More durable" read
/// as gibberish for a tea run, so the floor classifies the mission into a coarse ``MissionCategory``
/// and offers that category's chips (tea → "Organic", "Caffeine-free", "Bolder"), falling back to
/// generic chips only when the category is unknown. See issue #25.
public protocol RefineChipSuggester: Sendable {
    /// Suggests the quick chips for `mission` (the user's `profile` lets a model tier lean the
    /// suggestions toward their taste). Never throws: an unusable model tier degrades to the
    /// deterministic category taxonomy, which always returns a non-empty set.
    func chips(for mission: ShoppingTask, profile: TasteProfile) async -> [RefineChip]
}

/// A coarse product category inferred from a mission, used to pick chips that actually fit. Kept
/// deliberately small (the seed missions Crumb ships today plus a generic fallback) — issue #25
/// scopes this first pass to the categories the app demos, to be widened later.
public enum MissionCategory: String, CaseIterable, Sendable {
    /// Tea, coffee, and other drinks (the jasmine-tea E2E path and the seed `coffee` mission).
    case beverages
    /// Apparel and outdoor gear (the seed `hike` mission).
    case apparel
    /// Home goods, décor, and the workspace (the seed `desk` mission).
    case home
    /// Anything the classifier can't place — the neutral, always-safe chips.
    case generic

    /// Classifies a mission by scoring its text against each category's keywords and taking the
    /// clear winner. Pure and deterministic: the same mission always yields the same category. A
    /// zero score, or a tie for the top, resolves to ``generic`` so an ambiguous mission never gets
    /// misleading chips.
    public static func classify(_ mission: ShoppingTask) -> MissionCategory {
        // The mission's own words: title, subtitle, plan labels, and the catalog search queries.
        let text = ([mission.title, mission.subtitle] + mission.plan + mission.searchQueries)
            .joined(separator: " ")
            .lowercased()
        let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        let scored = scoredCategories.map { category, keywords -> (MissionCategory, Int) in
            let score = keywords.reduce(into: 0) { total, keyword in
                // Multi-word keywords ("pour over") match as substrings; single words match on a
                // token boundary so "tea" doesn't fire on "steak".
                let hit = keyword.contains(" ") ? text.contains(keyword) : tokens.contains(keyword)
                if hit { total += 1 }
            }
            return (category, score)
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return .generic }
        // A tie for the top is genuine ambiguity — don't guess.
        let topScore = best.1
        if scored.filter({ $0.1 == topScore }).count > 1 { return .generic }
        return best.0
    }

    /// The chips for this category. Each chip's `refinementText` is written so the deterministic
    /// ``RuleBasedRefinementInterpreter/heuristicDirective(for:)`` reads it into an actionable
    /// directive (a price lean or a re-ranking emphasis) — verified in `RefineChipSuggesterTests`.
    public var chips: [RefineChip] {
        switch self {
        case .beverages:
            return [
                .init(id: "cheaper", label: "Cheaper", refinementText: "make it cheaper"),
                .init(id: "organic", label: "Organic", refinementText: "organic, natural ingredients"),
                .init(id: "caffeine-free", label: "Caffeine-free", refinementText: "caffeine-free, gentler options"),
                .init(id: "bolder", label: "Bolder", refinementText: "bolder, richer flavor"),
            ]
        case .apparel:
            return [
                .init(id: "cheaper", label: "Cheaper", refinementText: "make it cheaper"),
                .init(id: "warmer", label: "Warmer", refinementText: "warmer tones and materials"),
                .init(id: "lighter", label: "Lighter", refinementText: "lighter, packs smaller"),
                .init(id: "durable", label: "More durable", refinementText: "more durable, built to last"),
            ]
        case .home:
            return [
                .init(id: "cheaper", label: "Cheaper", refinementText: "make it cheaper"),
                .init(id: "calmer", label: "Calmer", refinementText: "calmer, softer textures"),
                .init(id: "natural", label: "Natural", refinementText: "natural materials like wood and linen"),
                .init(id: "fewer", label: "Fewer", refinementText: "fewer, only the essentials"),
            ]
        case .generic:
            return [
                .init(id: "cheaper", label: "Cheaper", refinementText: "make it cheaper"),
                .init(id: "fewer", label: "Fewer", refinementText: "fewer, only the essentials"),
                .init(id: "nicer", label: "Nicer", refinementText: "nicer, higher-end picks"),
                .init(id: "durable", label: "More durable", refinementText: "more durable, built to last"),
            ]
        }
    }

    /// The classifier keyword sets, scored in this order. `generic` has none — it's the fallback.
    /// Keywords are lowercased; single words match a token, multi-word phrases match a substring.
    private static let scoredCategories: [(MissionCategory, [String])] = [
        (.beverages, [
            "tea", "teas", "coffee", "espresso", "matcha", "chai", "herbal", "kettle", "brew",
            "beans", "bean", "cocoa", "latte", "oolong", "kombucha", "cider", "tisane", "decaf",
            "caffeine", "grinder", "dripper", "pour over", "pour-over", "cold brew", "loose leaf",
        ]),
        (.apparel, [
            "hike", "hiking", "jacket", "shell", "waterproof", "rain", "boots", "boot", "socks",
            "sock", "layer", "midlayer", "apparel", "clothing", "clothes", "wear", "pack",
            "daypack", "backpack", "trail", "outdoor", "gear", "fleece", "merino", "wool", "cap",
            "hat", "gloves", "coat", "shoes", "warm", "dry", "camp", "camping",
        ]),
        (.home, [
            "desk", "light", "lamp", "clutter", "calm", "soft", "texture", "wood", "wooden",
            "felt", "plant", "organizer", "tray", "mat", "home", "decor", "room", "shelf",
            "cushion", "candle", "living", "tidy", "surface", "mug", "ceramic", "linen", "vase",
            "rug", "cozy", "minimalist",
        ]),
    ]
}

/// Deterministic, offline ``RefineChipSuggester`` — the default for the scaffold and the only
/// suggester that runs on the simulator/CI (where the on-device model is unavailable) and in
/// headless screenshots. It classifies the mission into a ``MissionCategory`` and returns that
/// category's chips. Pure (no model, no I/O) — the unit-tested guarantee behind the seam.
public struct RuleBasedRefineChipSuggester: RefineChipSuggester {

    public init() {}

    public func chips(for mission: ShoppingTask, profile: TasteProfile) async -> [RefineChip] {
        Self.chips(for: mission)
    }

    /// The pure classification the whole seam funnels through — the sync floor the app shows
    /// instantly and the degrade target every model tier falls back to.
    public static func chips(for mission: ShoppingTask) -> [RefineChip] {
        MissionCategory.classify(mission).chips
    }
}
