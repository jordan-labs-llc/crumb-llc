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
        rankedByProfile(products, for: profile)
    }

    public func rank(_ products: [Product], for profile: TasteProfile, mission: ShoppingTask) -> [Product] {
        guard Self.isPremiumJasmineTeaMission(mission) else {
            return rankedByProfile(products, for: profile)
        }
        return rankedForPremiumJasmineTea(products, for: profile)
    }

    public func curate(
        _ products: [Product],
        for profile: TasteProfile,
        mission: ShoppingTask,
        refinement: RefinementContext?,
        recipient: RecipientRef?
    ) async -> CuratedDeck {
        let ranked = rank(products, for: profile, mission: mission)
        let shaped = RefinementContext.apply(refinement, to: ranked)
        let voiced = shaped.map { product in
            product.withRationale(rationale(for: product, profile: profile, recipient: recipient, mission: mission))
        }
        return CuratedDeck(products: voiced, tier: .ruleBased(nil))
    }

    private func rankedByProfile(_ products: [Product], for profile: TasteProfile) -> [Product] {
        // Stable, deterministic sort: higher score first, ties broken by id so the order
        // never wobbles between runs.
        struct Scored {
            let product: Product
            let score: Double
        }
        let scored: [Scored] = products.map { product in
            Scored(product: product, score: score(product, for: profile))
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.product.id < rhs.product.id
                : lhs.score > rhs.score
        }
        return ranked.map(\.product)
    }

    private func rankedForPremiumJasmineTea(_ products: [Product], for profile: TasteProfile) -> [Product] {
        struct Scored {
            let product: Product
            let score: Double
        }
        let scored = products.map { product in
            Scored(
                product: product,
                score: Self.premiumJasmineTeaScore(for: product) + score(product, for: profile) * 0.1
            )
        }
        return scored.sorted { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.product.id < rhs.product.id
                : lhs.score > rhs.score
        }.map(\.product)
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

        if !echoesLeaning,
           let teaRationale = Self.premiumJasmineTeaRationale(for: product, mission: mission, recipient: recipient) {
            return teaRationale
        }

        guard let recipient else {
            // Owner voice. A rationale that already echoes a leaning is our own seed voice — it
            // reads as Crumb, so keep it verbatim. Otherwise it's the raw merchant blurb of a live
            // catalog item: never pass that off as the curator's "why this is you" (#22) — speak a
            // short curator line instead, honest about carrying no invented facts.
            if echoesLeaning { return product.rationale }
            return ownerFloor(mission: mission, leaning: leaning)
        }

        // Gift voice — addressed to the recipient by name. Same rule: keep our seed voice, but never
        // hand off the raw merchant blurb as the curator's gift note.
        let name = recipient.name
        if echoesLeaning {
            return "\(product.rationale) A gift for \(name)."
        }
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

    // MARK: - Premium jasmine tea floor (#58)

    static func isPremiumJasmineTeaMission(_ mission: ShoppingTask?) -> Bool {
        guard let mission else { return false }
        let words = RuleBasedRelevanceGate.tokens(
            ([mission.title, mission.subtitle] + mission.plan + mission.searchQueries)
                .joined(separator: " ")
        )
        return words.contains("jasmine") && words.contains("tea") && words.contains("premium")
    }

    static func premiumJasmineTeaScore(for product: Product) -> Double {
        let text = teaText(for: product)
        let words = RuleBasedRelevanceGate.tokens(text)
        var score = 0.0

        if words.contains("jasmine") { score += 4.0 }
        if words.contains("tea") { score += 1.0 }

        let qualityMatches = premiumTeaQualitySignals.filter { text.contains($0) }
        score += min(3.0, Double(qualityMatches.count) * 0.55)

        if specialtyTeaMerchant(product) { score += 1.0 }
        if text.contains("rishi") || text.contains("goldenmoon") || text.contains("golden moon") {
            score += 0.6
        }

        let price = NSDecimalNumber(decimal: product.price).doubleValue
        if (15...80).contains(price) { score += 0.45 }
        if price < 8 { score -= 1.4 }
        if price > 120 { score -= 0.35 }

        if looksLikeSampleOrSachet(product) { score -= 1.6 }
        if looksLikeBulkOrFoodservice(product) { score -= 1.6 }
        if genericJasmineTea(product) { score -= 1.0 }
        if looksCrossBorder(product) { score -= 0.25 }
        if !words.contains("jasmine") { score -= 4.0 }

        return score
    }

    static func premiumJasmineTeaRationale(
        for product: Product,
        mission: ShoppingTask?,
        recipient: RecipientRef?
    ) -> String? {
        guard isPremiumJasmineTeaMission(mission),
              RuleBasedRelevanceGate.tokens(teaText(for: product)).contains("jasmine")
        else { return nil }

        let subject = recipient.map { " for \($0.name)" } ?? ""
        if looksLikeSampleOrSachet(product) {
            return "Jasmine sample option\(subject): easy to try, but less premium than the loose-leaf picks."
        }
        if looksLikeBulkOrFoodservice(product) {
            return "Bulk jasmine tea\(subject): useful for quantity, but not the strongest premium personal pick."
        }

        var signals: [String] = []
        let text = teaText(for: product)
        if text.contains("loose leaf") || text.contains("loose-leaf") {
            signals.append("loose-leaf")
        }
        if text.contains("pearl") || text.contains("dragon") {
            signals.append("jasmine pearl")
        }
        if text.contains("whole leaf") {
            signals.append("whole-leaf")
        }
        if text.contains("organic") {
            signals.append("organic")
        }
        if specialtyTeaMerchant(product) {
            signals.append("specialty tea merchant")
        }

        if signals.isEmpty {
            let missionTitle = mission?.title ?? "premium jasmine tea"
            var line = "Jasmine tea fit\(subject): \(missionTitle) is on-mission, but check for leaf grade and scenting details."
            if looksCrossBorder(product) {
                line += " Cross-border seller; compare shipping before checkout."
            }
            return line
        }

        var line = "Premium jasmine fit\(subject): \(signals.prefix(3).joined(separator: ", ")) signals make it more credible than a generic tea result."
        if looksCrossBorder(product) {
            line += " Cross-border seller; compare shipping before checkout."
        }
        return line
    }

    private static let premiumTeaQualitySignals = [
        "loose leaf", "loose-leaf", "whole leaf", "organic", "pearl", "pearls", "dragon",
        "silver needle", "green tea", "scented", "scenting", "origin", "estate",
    ]

    private static func teaText(for product: Product) -> String {
        "\(product.name) \(product.rationale) \(product.shop.id) \(product.shop.name)"
            .lowercased()
    }

    private static func specialtyTeaMerchant(_ product: Product) -> Bool {
        let shop = "\(product.shop.id) \(product.shop.name)".lowercased()
        return shop.contains("rishi")
            || shop.contains("goldenmoontea")
            || shop.contains("golden moon")
            || shop.contains("davidstea")
            || shop.contains("genuinetea")
            || shop.contains("theteatime")
            || shop.contains("teavivre")
            || shop.contains("verdant")
            || shop.contains("harney")
            || shop.contains("tea.com")
            || shop.contains("-tea.")
            || shop.contains("tea-")
    }

    private static func looksLikeSampleOrSachet(_ product: Product) -> Bool {
        let text = teaText(for: product)
        return text.contains("sachet")
            || text.contains("sachets")
            || text.contains("sample")
            || text.contains("tea bag")
            || text.contains("tea bags")
            || text.contains("teabag")
            || text.contains("teabags")
            || text.contains("pyramid tea")
            || text.contains("individually wrapped")
            || text.contains("pack of 12")
    }

    private static func looksLikeBulkOrFoodservice(_ product: Product) -> Bool {
        let text = teaText(for: product)
        return text.contains("foodservice")
            || text.contains("bulk")
            || text.contains("case of")
            || text.contains("case pack")
            || text.contains("wholesale")
    }

    private static func genericJasmineTea(_ product: Product) -> Bool {
        let title = product.name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let qualityMatches = premiumTeaQualitySignals.filter { teaText(for: product).contains($0) }
        return (title == "jasmine tea" || title == "jasmine") && qualityMatches.isEmpty
    }

    private static func looksCrossBorder(_ product: Product) -> Bool {
        let shop = "\(product.shop.id) \(product.shop.name)".lowercased()
        return shop.contains(".co.uk")
            || shop.contains(".uk")
            || shop.contains(".ca")
            || shop.contains(".eu")
            || shop.contains(".au")
    }
}
