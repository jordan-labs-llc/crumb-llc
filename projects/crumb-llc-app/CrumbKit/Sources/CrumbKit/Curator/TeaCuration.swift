import Foundation

/// Category-aware tea curation (#58): a deterministic scoring + rationale layer that makes a
/// "premium jasmine tea"-style mission rank credible specialty picks first and explain concrete
/// quality signals — instead of leading with a generic or budget listing under generic copy.
///
/// Pure and model-free — the unit-tested floor. ``RuleBasedCurator`` applies it, so it drives the
/// sim/CI deck, the streamed pre-settle deck, the baseline the model reconciles against, and the
/// degraded fallback; the on-device model tier is a richer voice layered over this same judgment.
///
/// It reads only what a live catalog card actually carries — title (`name`), merchant blurb
/// (`rationale`), size (`variants.title`), price, and seller domain (`shop`) — and never invents
/// facts (no ratings/reviews to cite, and buyer locale isn't known, so cross-border shipping is left
/// to a follow-up rather than asserted).
enum TeaCuration {

    /// A tea product's premium standing, read from its title / blurb / size.
    enum Grade: Sendable, Equatable {
        case premium   // loose-leaf / whole-leaf / pearls / single-origin / organic specialty
        case generic   // a named tea with no quality detail
        case sachet    // tea bags / sachets / pyramids
        case sample    // sample / trial / mini size
        case bulk      // foodservice / case / wholesale
    }

    // MARK: Mission gate

    /// Whether the mission is a tea search — the category this layer speaks to.
    static func isTeaMission(_ mission: ShoppingTask) -> Bool {
        containsWord(missionText(mission), "tea")
    }

    /// Whether the mission asks for *premium* tea specifically — tightens price plausibility.
    static func wantsPremium(_ mission: ShoppingTask) -> Bool {
        let t = missionText(mission)
        return premiumIntentCues.contains { t.contains($0) }
    }

    private static let premiumIntentCues = [
        "premium", "fine", "specialty", "high-grade", "high grade", "top", "best", "luxury", "artisan",
    ]

    private static func missionText(_ m: ShoppingTask) -> String {
        "\(m.title) \(m.subtitle) \(m.plan.joined(separator: " ")) \(m.searchQueries.joined(separator: " "))"
            .lowercased()
    }

    // MARK: Grade

    static func grade(_ p: Product) -> Grade {
        let hay = haystack(p)
        if bulkCues.contains(where: hay.contains) { return .bulk }
        if sampleCues.contains(where: hay.contains) { return .sample }
        if sachetCues.contains(where: hay.contains) { return .sachet }
        if premiumCues.contains(where: hay.contains) { return .premium }
        return .generic
    }

    private static let premiumCues = [
        "loose leaf", "loose-leaf", "loose tea", "loose ", "whole leaf", "whole-leaf", "leaves",
        "pearl", "silver needle", "first flush", "single origin", "single-origin", "hand-rolled",
        "hand rolled", "scented", "organic", "reserve", "ceremonial", "artisan", "estate",
        "gongfu", "gong fu",
    ]
    private static let sachetCues = ["sachet", "tea bag", "teabag", "tea bags", "pyramid", "bags of"]
    private static let sampleCues = ["sample", "sampler", "trial", "mini ", "travel size", "tasting set"]
    private static let bulkCues = [
        "foodservice", "food service", "wholesale", "bulk", "case of", "carton", "pack of 12",
        "pack of 24", "pack of 50", "pack of 100", "1000", "catering",
    ]

    private static func haystack(_ p: Product) -> String {
        "\(p.name) \(p.rationale) \(p.variants.map(\.title).joined(separator: " "))".lowercased()
    }

    // MARK: Scoring

    /// A deterministic ranking adjustment for a tea mission — added on top of RuleBasedCurator's base
    /// score (which is ~0 for live catalog items that carry no ratings). Premium/specialty picks rise;
    /// sachets, samples, bulk/foodservice, and implausibly cheap listings sink, so an obvious budget
    /// or sample pick never sits above a stronger premium option without justification. `0` for a
    /// non-tea mission, so every other category is untouched.
    static func scoreAdjustment(_ p: Product, mission: ShoppingTask) -> Double {
        guard isTeaMission(mission) else { return 0 }
        var s: Double
        switch grade(p) {
        case .premium: s = 1.0
        case .generic: s = 0.0
        case .sachet:  s = -0.3
        case .sample:  s = -0.6
        case .bulk:    s = -0.9
        }
        if isSpecialtyTeaMerchant(p) { s += 0.4 }
        if matchesMissionVariety(p, mission: mission) { s += 0.3 }
        // Price plausibility only bites when the user asked for *premium*: a credible price lifts, an
        // implausibly low one (that isn't itself clearly premium) sinks toward the sample/value tail.
        if wantsPremium(mission) {
            let price = NSDecimalNumber(decimal: p.price).doubleValue
            if price >= premiumPlausibleFloor {
                s += 0.2
            } else if price < budgetSuspectCeiling && grade(p) != .premium {
                s -= 0.3
            }
        }
        return s
    }

    private static let premiumPlausibleFloor = 15.0
    private static let budgetSuspectCeiling = 8.0

    /// A credible specialty tea merchant — the seller domain reads as a tea shop. Not a hard signal
    /// (many generalists sell tea), so it's a bonus, never a gate.
    static func isSpecialtyTeaMerchant(_ p: Product) -> Bool {
        let d = "\(p.shop.id) \(p.shop.name)".lowercased()
        return d.contains("tea") || knownTeaMerchants.contains { d.contains($0) }
    }

    private static let knownTeaMerchants = [
        "rishi", "goldenmoon", "golden moon", "jing", "adagio", "harney", "davidstea",
        "teavana", "kusmi", "vahdam", "yunnan", "mariage",
    ]

    /// Whether the product names the same tea variety the mission asked for (e.g. jasmine → jasmine).
    static func matchesMissionVariety(_ p: Product, mission: ShoppingTask) -> Bool {
        let hay = haystack(p)
        let wanted = teaVarieties.filter { containsWord(missionText(mission), $0) }
        return wanted.contains { hay.contains($0) }
    }

    private static let teaVarieties = [
        "jasmine", "oolong", "matcha", "sencha", "genmaicha", "earl grey", "pu-erh", "puerh",
        "white", "green", "black", "chai", "darjeeling", "assam", "gunpowder", "chamomile", "rooibos",
    ]

    /// The first tea variety the mission names, for phrasing the rationale ("jasmine" → "jasmine tea").
    static func missionVariety(_ mission: ShoppingTask) -> String {
        teaVarieties.first { containsWord(missionText(mission), $0) } ?? ""
    }

    // MARK: Rationale

    /// A concrete, quality-naming rationale for a tea card — the "premium pick / value / sample /
    /// sachets" distinction the deck owes a discerning buyer. `nil` for a non-tea mission (the caller
    /// falls back to the generic mission-anchored floor). Names the specific premium signal it found,
    /// or honestly flags a sachet / sample / bulk / detail-light listing.
    static func rationale(_ p: Product, mission: ShoppingTask) -> String? {
        guard isTeaMission(mission) else { return nil }
        let specialty = isSpecialtyTeaMerchant(p)
        let phrase = varietyPhrase(missionVariety(mission))        // "jasmine tea" / "tea"
        switch grade(p) {
        case .premium:
            let lead = premiumLead(hay: haystack(p), phrase: phrase)
            return specialty
                ? "\(lead) from a specialty tea merchant — the most premium fit in this set."
                : "\(lead) — a genuine premium pick in this set."
        case .generic:
            if specialty {
                return "\(capitalized(phrase)) from a specialty tea merchant — a solid premium option, "
                    + "though the listing keeps the leaf grade brief."
            }
            return "\(capitalized(phrase)), but the listing doesn't name the leaf grade or origin — "
                + "a fair pick, not the premium standout."
        case .sachet:
            return "\(capitalized(phrase)) in sachets — easy to brew, but less premium than the loose-leaf options."
        case .sample:
            return "A small, value-size \(phrase) — fine to sample, but not the premium pick here."
        case .bulk:
            return "A bulk / foodservice pack — more \(phrase) than a personal premium cup calls for."
        }
    }

    /// Leads a premium rationale with the concrete signal detected in the listing.
    private static func premiumLead(hay: String, phrase: String) -> String {
        if hay.contains("pearl") { return "Hand-rolled \(phrase) pearls" }
        if hay.contains("loose") || hay.contains("whole leaf") || hay.contains("whole-leaf") {
            return "Loose-leaf \(phrase)"
        }
        if hay.contains("organic") { return "Organic \(phrase)" }
        if hay.contains("single origin") || hay.contains("single-origin") || hay.contains("estate") {
            return "Single-origin \(phrase)"
        }
        return "Premium \(phrase)"
    }

    private static func varietyPhrase(_ variety: String) -> String {
        variety.isEmpty ? "tea" : "\(variety) tea"
    }

    private static func capitalized(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return first.uppercased() + phrase.dropFirst()
    }

    /// Word-boundary-aware `contains` so "tea" doesn't match "steal" and "green" is a whole word —
    /// the mission-text/variety matching stays honest.
    private static func containsWord(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        if word.contains(" ") { return text.contains(word) }   // multi-word cue: plain contains
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: word, range: searchRange) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let boundaryBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
            let boundaryAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if boundaryBefore && boundaryAfter { return true }
            searchRange = r.upperBound..<text.endIndex
        }
        return false
    }
}
