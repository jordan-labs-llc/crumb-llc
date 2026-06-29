import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the conversational-refinement seam. The model call itself
/// stays untested (unavailable on CI/sim, exactly like the curator/planner/extractor) — but the
/// rule-based heuristic, the pure `cleanDirective` / `directive(from:tier:)` reconcile, and the
/// `RefinementContext.apply` deck shaping are exercised exhaustively here.
@Suite("RefinementInterpreter")
struct RefinementInterpreterTests {

    // MARK: Rule-based floor — chips

    @Test("Each quick chip interprets into the directive it promises")
    func chipDirectives() {
        let cheaper = RuleBasedRefinementInterpreter.heuristicDirective(for: RuleBasedRefinementInterpreter.Chip.cheaper.refinementText)
        #expect(cheaper.priceDirection == .cheaper)

        for chip in [RuleBasedRefinementInterpreter.Chip.warmer, .fewer, .durable] {
            let directive = RuleBasedRefinementInterpreter.heuristicDirective(for: chip.refinementText)
            #expect(!directive.emphasis.isEmpty, "chip: \(chip)")   // re-rank/re-voice note
            #expect(directive.addQueries.isEmpty, "chip: \(chip)")  // chips never search
        }
        #expect(RuleBasedRefinementInterpreter.Chip.allCases.count == 4)
    }

    // MARK: Rule-based floor — free-text heuristic

    @Test("Price words set a price direction (and 'cheaper' is never read as a removal)")
    func priceHeuristic() {
        #expect(RuleBasedRefinementInterpreter.heuristicDirective(for: "make it cheaper").priceDirection == .cheaper)
        #expect(RuleBasedRefinementInterpreter.heuristicDirective(for: "something more budget").priceDirection == .cheaper)
        #expect(RuleBasedRefinementInterpreter.heuristicDirective(for: "I'd splurge here").priceDirection == .pricier)
        // A pure price ask carries no emphasis and no removal — the sort is the change.
        let cheaper = RuleBasedRefinementInterpreter.heuristicDirective(for: "make it cheaper")
        #expect(cheaper.emphasis.isEmpty)
        #expect(cheaper.removeHints.isEmpty)
    }

    @Test("An add-lead pulls a search query; a remove-lead pulls a demote hint")
    func addAndRemoveHeuristic() {
        let add = RuleBasedRefinementInterpreter.heuristicDirective(for: "add rain pants")
        #expect(add.addQueries == ["rain pants"])

        let need = RuleBasedRefinementInterpreter.heuristicDirective(for: "I also need a headlamp")
        #expect(need.addQueries == ["a headlamp"])

        let remove = RuleBasedRefinementInterpreter.heuristicDirective(for: "no synthetic")
        #expect(remove.removeHints == ["synthetic"])
        #expect(remove.addQueries.isEmpty)
    }

    @Test("Anything else becomes an emphasis note")
    func emphasisHeuristic() {
        let directive = RuleBasedRefinementInterpreter.heuristicDirective(for: "warmer earthy tones")
        #expect(directive.emphasis == "warmer earthy tones")
        #expect(directive.priceDirection == .none)
        #expect(directive.addQueries.isEmpty)
        #expect(directive.removeHints.isEmpty)
    }

    @Test("An empty refinement is not actionable")
    func emptyNotActionable() {
        #expect(!RuleBasedRefinementInterpreter.heuristicDirective(for: "   ").isActionable)
        #expect(RefinementDirective().isActionable == false)
    }

    @Test("The floor reports the chosen default quietly, but a degraded AI tier reports its reason")
    func tierReporting() async {
        let quiet = await RuleBasedRefinementInterpreter().interpret(
            "make it cheaper", conversation: ["make it cheaper"],
            mission: SeedData.hike, profile: SeedData.defaultTasteProfile
        )
        #expect(quiet.tier == .ruleBased(nil))
        #expect(quiet.tier.fallbackNote == nil)

        let degraded = RuleBasedRefinementInterpreter.interpret(text: "warmer tones", reason: .offlineOrError)
        #expect(degraded.tier == .ruleBased(.offlineOrError))
        #expect(degraded.tier.fallbackNote != nil)
    }

    // MARK: cleanDirective (shared reconcile)

    @Test("cleanDirective trims, drops blanks, dedupes, and caps addQueries")
    func cleanDirectiveCaps() {
        let raw = RefinementDirective(
            emphasis: "  warmer  ",
            addQueries: ["rain pants", "Rain Pants", " ", "gloves", "hat", "scarf"],  // dup + blank + over cap
            priceDirection: .cheaper,
            removeHints: ["  synthetic ", "synthetic", ""]
        )
        let clean = RuleBasedRefinementInterpreter.cleanDirective(raw)
        #expect(clean.emphasis == "warmer")
        #expect(clean.addQueries == ["rain pants", "gloves", "hat"])   // deduped (case-insensitive), capped at 3
        #expect(clean.addQueries.count == RefinementDirective.maxAddQueries)
        #expect(clean.removeHints == ["synthetic"])                    // trimmed + deduped
        #expect(clean.priceDirection == .cheaper)
    }

    // MARK: directive(from:tier:) (the pure fold of a model draft)

    @Test("A model draft folds into a clean directive, mapping the price string and preserving the tier")
    func draftReconcile() {
        let draft = RefinementDraft(
            emphasis: "  warmer tones  ",
            priceDirection: "CHEAPER",
            addQueries: ["rain pants", "rain pants"],
            removeHints: ["synthetic"]
        )
        let interpreted = AppleFoundationRefinementInterpreter.directive(from: draft, tier: .onDevice)
        #expect(interpreted.directive.emphasis == "warmer tones")
        #expect(interpreted.directive.priceDirection == .cheaper)
        #expect(interpreted.directive.addQueries == ["rain pants"])    // deduped
        #expect(interpreted.directive.removeHints == ["synthetic"])
        #expect(interpreted.tier == .onDevice)                         // proven tier preserved
    }

    @Test("An unrecognized price string maps to .none")
    func draftUnknownPrice() {
        let draft = RefinementDraft(emphasis: "", priceDirection: "dunno", addQueries: [], removeHints: [])
        let interpreted = AppleFoundationRefinementInterpreter.directive(from: draft, tier: .privateCloud)
        #expect(interpreted.directive.priceDirection == .none)
        #expect(!interpreted.directive.isActionable)
    }

    // MARK: RefinementContext.apply (deterministic deck shaping)

    @Test("A cheaper directive stable-sorts the deck by ascending price")
    func applyPriceSort() {
        let directive = RefinementDirective(priceDirection: .cheaper)
        let context = RefinementContext(directive: directive, conversation: ["cheaper"])
        let shaped = RefinementContext.apply(context, to: SeedData.hikeProducts)

        let prices = shaped.map(\.price)
        #expect(prices == prices.sorted(by: <))                        // non-decreasing
        #expect(Set(shaped.map(\.id)) == Set(SeedData.hikeProducts.map(\.id)))  // nothing lost
    }

    @Test("An emphasis keyword boosts matching products to the front")
    func applyEmphasisBoost() {
        let directive = RefinementDirective(emphasis: "merino")           // matches the merino socks
        let context = RefinementContext(directive: directive, conversation: ["merino"])
        let shaped = RefinementContext.apply(context, to: SeedData.hikeProducts)
        #expect(shaped.first?.id == "hike.socks")
        #expect(shaped.count == SeedData.hikeProducts.count)
    }

    @Test("A remove hint demotes matching products to the tail without dropping them")
    func applyRemoveDemote() {
        let directive = RefinementDirective(removeHints: ["down"])        // matches the down midlayer
        let context = RefinementContext(directive: directive, conversation: ["no down"])
        let shaped = RefinementContext.apply(context, to: SeedData.hikeProducts)
        #expect(shaped.last?.id == "hike.midlayer")
        #expect(shaped.count == SeedData.hikeProducts.count)             // demoted, not dropped
    }

    @Test("A nil or non-actionable directive leaves the deck untouched")
    func applyNoOp() {
        #expect(RefinementContext.apply(nil, to: SeedData.hikeProducts).map(\.id) == SeedData.hikeProducts.map(\.id))
        let empty = RefinementContext(directive: RefinementDirective(), conversation: [])
        #expect(RefinementContext.apply(empty, to: SeedData.hikeProducts).map(\.id) == SeedData.hikeProducts.map(\.id))
    }

    @Test("Combined asks compose: price sort, then emphasis boost, then remove demote")
    func applyCombined() {
        let directive = RefinementDirective(
            emphasis: "merino", priceDirection: .cheaper, removeHints: ["down"]
        )
        let context = RefinementContext(directive: directive, conversation: ["cheaper merino, no down"])
        let shaped = RefinementContext.apply(context, to: SeedData.hikeProducts)
        #expect(shaped.first?.id == "hike.socks")          // emphasis wins the front
        #expect(shaped.last?.id == "hike.midlayer")        // removal sinks to the tail
        #expect(shaped.count == SeedData.hikeProducts.count)
    }
}
