import Foundation

/// Deterministic, offline curator. This is the default ``CuratorEngine`` for the
/// scaffold: it uses the seed `plan`/`rationale` and a simple profile-weighted sort.
///
/// ## Future seam — `FoundationModelsCurator`
/// A later implementation can use Apple's on-device model behind this same protocol:
///
/// ```swift
/// // import FoundationModels
/// // @available(iOS 27, macOS 27, visionOS 27, *)
/// // struct FoundationModelsCurator: CuratorEngine {
/// //     func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
/// //         guard SystemLanguageModel.default.isAvailable else {
/// //             return RuleBasedCurator().rank... // graceful fallback
/// //         }
/// //         let session = LanguageModelSession()
/// //         ... // prompt the model with the profile + candidates
/// //     }
/// // }
/// ```
///
/// Inference is intentionally **not** implemented in this pass.
public struct RuleBasedCurator: CuratorEngine {

    public init() {}

    public func plan(for task: ShoppingTask) async -> [String] {
        task.plan
    }

    public func rank(_ products: [Product], for profile: TasteProfile) async -> [Product] {
        rank(products, for: profile, mission: nil)
    }

    /// Mission-aware ranking (#58): the base profile-fit sort, plus a category-aware adjustment for
    /// tea missions (``TeaCuration``) so a "premium jasmine tea" search leads with credible specialty
    /// picks and pushes sachets / samples / bulk / implausibly-cheap listings down. `mission == nil`
    /// (and every non-tea mission) reproduces the base sort byte-for-byte, so nothing else shifts.
    public func rank(_ products: [Product], for profile: TasteProfile, mission: ShoppingTask?) -> [Product] {
        // Stable, deterministic sort: higher score first, ties broken by id so the order
        // never wobbles between runs.
        struct Scored {
            let product: Product
            let score: Double
        }
        let scored: [Scored] = products.map { product in
            let categoryAdjustment = mission.map { TeaCuration.scoreAdjustment(product, mission: $0) } ?? 0
            return Scored(product: product, score: score(product, for: profile) + categoryAdjustment)
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.product.id < rhs.product.id
                : lhs.score > rhs.score
        }
        return ranked.map(\.product)
    }

    public func rationale(for product: Product, profile: TasteProfile) -> String {
        rationale(for: product, profile: profile, recipient: nil, mission: nil)
    }

    public func rationale(for product: Product, profile: TasteProfile, recipient: RecipientRef?) -> String {
        rationale(for: product, profile: profile, recipient: recipient, mission: nil)
    }

    /// Gift- **and** mission-aware deterministic voice — **this is what renders on the sim/CI** (no
    /// model), so it's the unit-tested floor. A rationale that already echoes a leaning is our own
    /// seed voice and is always kept verbatim (the gift path tags it "A gift for Mom."). Otherwise
    /// the floor is:
    ///
    /// - **With a mission** (#33): anchored to *that mission* — "A steady pick for “Premium jasmine
    ///   tea”." — so the line reads on-topic even against the skipped-onboarding default profile. A
    ///   taste leaning is named only when it genuinely touches the mission, so a hiking "merino over
    ///   synthetic" no longer lands on a tea card.
    /// - **Without a mission** (`mission == nil`): today's mission-agnostic behavior, unchanged — a
    ///   quiet "Fits your lean toward …" nod on the owner's first stated leaning (or a generic line),
    ///   addressed to the recipient by name in the gift path.
    public func rationale(
        for product: Product,
        profile: TasteProfile,
        recipient: RecipientRef?,
        mission: ShoppingTask?
    ) -> String {
        let lowered = product.rationale.lowercased()
        let echoesLeaning = profile.leanings.contains { lowered.contains(keyword(from: $0)) }

        // Which leaning, if any, to name. With no mission we keep today's behavior — the first
        // stated leaning, whether or not it fits. With a mission we name a leaning only when its
        // keyword actually shows up in the mission, so an unrelated default leaning is left off (#33).
        let leaning: String? = {
            guard let mission else { return profile.leanings.first }
            return profile.leanings.first { missionMentions(keyword(from: $0), in: mission) }
        }()

        // #58: for a tea mission with no fitting leaning to name, speak concrete tea-quality voice
        // (premium pick / value / sample / sachets) instead of the generic "A steady pick for …"
        // floor — the trust signal a discerning tea buyer is owed. A fitting leaning still wins (its
        // named nod is preserved below), and seed voice is always kept verbatim.
        let teaLine: String? = {
            guard leaning == nil, let mission else { return nil }
            return TeaCuration.rationale(product, mission: mission)
        }()

        guard let recipient else {
            // Owner voice. A rationale that already echoes a leaning is our own seed voice — it
            // reads as Crumb, so keep it verbatim. Otherwise it's the raw merchant blurb of a live
            // catalog item: never pass that off as the curator's "why this is you" (#22) — speak a
            // short curator line instead, honest about carrying no invented facts.
            if echoesLeaning { return product.rationale }
            if let teaLine { return teaLine }
            return ownerFloor(mission: mission, leaning: leaning)
        }

        // Gift voice — addressed to the recipient by name. Same rule: keep our seed voice, but never
        // hand off the raw merchant blurb as the curator's gift note.
        let name = recipient.name
        if echoesLeaning {
            return "\(product.rationale) A gift for \(name)."
        }
        if let teaLine { return "\(teaLine) A gift for \(name)." }
        return giftFloor(name: name, mission: mission, leaning: leaning)
    }

    /// The owner floor line. Mission-anchored when a mission is present (#33); otherwise the
    /// mission-agnostic leaning nod, byte-for-byte today's copy.
    private func ownerFloor(mission: ShoppingTask?, leaning: String?) -> String {
        guard let mission else {
            if let leaning { return "A pick that fits your lean toward \(leaning.lowercased())." }
            return Self.genericOwnerVoice
        }
        if let leaning {
            return "A steady pick for \(missionAnchor(mission)), true to your lean toward \(leaning.lowercased())."
        }
        return "A steady pick for \(missionAnchor(mission))."
    }

    /// The gift floor line, addressed to `name`. Mission-anchored when present (#33); otherwise the
    /// mission-agnostic gift nod, byte-for-byte today's copy.
    private func giftFloor(name: String, mission: ShoppingTask?, leaning: String?) -> String {
        guard let mission else {
            if let leaning { return "A gift that fits \(possessive(name))'s lean toward \(leaning.lowercased())." }
            return "A gift picked with \(name) in mind."
        }
        if let leaning {
            return "A steady \(missionAnchor(mission)) pick for \(name), true to \(possessive(name))'s lean toward \(leaning.lowercased())."
        }
        return "A steady \(missionAnchor(mission)) pick, chosen for \(name)."
    }

    /// The mission, quoted for a rationale line — mirrors ``MissionBlock`` so the floor reads
    /// on-topic for any goal (a noun-phrase "premium jasmine tea" *or* an imperative "pack me for a
    /// hike") without inventing facts about the product.
    private func missionAnchor(_ mission: ShoppingTask) -> String {
        "\u{201C}\(mission.title)\u{201D}"
    }

    /// Whether the mission's title or subtitle mentions `keyword` (a lowercased substring) — the
    /// deterministic test for whether a stated leaning genuinely fits this mission (#33).
    private func missionMentions(_ keyword: String, in mission: ShoppingTask) -> Bool {
        "\(mission.title) \(mission.subtitle)".lowercased().contains(keyword)
    }

    /// The owner-voice floor when there's neither a seed-voiced rationale to keep nor a stated
    /// leaning to lean on — a short, honest curator line that invents nothing (live products carry
    /// no ratings or reviews to cite).
    static let genericOwnerVoice = "A considered pick for what you're after."

    /// The base for a possessive — Crumb writes "Mom's", "Dad's", "Alex's". We append "'s" in the
    /// caller, so this just yields the name; kept as a seam in case a name already ends in "s" and we
    /// later want "Chris'" styling. For now every name takes "'s".
    private func possessive(_ name: String) -> String { name }

    // MARK: - Scoring

    /// A deterministic fit score in roughly `0…1.4`.
    private func score(_ product: Product, for profile: TasteProfile) -> Double {
        // Base: normalized rating (4.0…5.0 → 0…1), nudged by review volume confidence.
        let ratingComponent = max(0, (product.rating - 4.0)) // 0…1 for 4.0–5.0
        let reviewConfidence = min(1.0, Double(product.reviews) / 1_500.0) * 0.1

        // Budget fit: a thrifty profile (low budgetComfort) prefers cheaper items; a
        // splurge-happy profile is indifferent. Normalize price across the seed range.
        let priceNorm = min(1.0, NSDecimalNumber(decimal: product.price).doubleValue / 250.0)
        let budgetPenalty = (1.0 - profile.budgetComfort) * priceNorm * 0.3

        // Leaning match: small bonus when the rationale echoes a stated leaning.
        let lowered = product.rationale.lowercased()
        let leaningBonus = profile.leanings
            .contains { lowered.contains(keyword(from: $0)) } ? 0.2 : 0.0

        return ratingComponent + reviewConfidence + leaningBonus - budgetPenalty
    }

    /// The first meaningful word of a leaning, lowercased (e.g. "Merino over synthetic"
    /// → "merino"), used for loose substring matching against rationales.
    private func keyword(from leaning: String) -> String {
        leaning.split(separator: " ").first.map { $0.lowercased() } ?? leaning.lowercased()
    }
}
