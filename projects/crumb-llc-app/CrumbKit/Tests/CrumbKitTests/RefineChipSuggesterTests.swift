import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the mission-fit refine-chip seam (issue #25). The model
/// call itself stays untested (unavailable on CI/sim, exactly like the curator/planner/interpreter)
/// — but the ``MissionCategory`` classifier, every chip's routing through the interpreter, and the
/// pure ``AppleFoundationRefineChipSuggester/reconcile(draft:floor:)`` are exercised here.
@Suite("RefineChipSuggester")
struct RefineChipSuggesterTests {

    // MARK: Classification

    @Test("The seed missions classify into the category they belong to")
    func seedMissionCategories() {
        #expect(MissionCategory.classify(SeedData.hike) == .apparel)
        #expect(MissionCategory.classify(SeedData.coffee) == .beverages)
        // The desk mission mentions a coffee mug, but the home signal must dominate.
        #expect(MissionCategory.classify(SeedData.desk) == .home)
    }

    @Test("A tea mission reads as beverages — the motivating case from #25")
    func teaMissionIsBeverages() {
        let tea = ShoppingTask(
            id: "tea",
            title: "Jasmine tea for Maya's birthday",
            subtitle: "loose leaf · floral",
            plan: ["Loose-leaf jasmine", "A steeping pot"],
            curatorNote: "",
            accentHex: 0x000000,
            candidateIDs: [],
            searchQueries: ["jasmine green tea", "glass teapot"]
        )
        #expect(MissionCategory.classify(tea) == .beverages)
    }

    @Test("A mission with no category signal falls back to generic")
    func unknownMissionIsGeneric() {
        let vague = ShoppingTask(
            id: "vague",
            title: "Surprise me",
            subtitle: "anything goes",
            plan: ["Something thoughtful"],
            curatorNote: "",
            accentHex: 0x000000,
            candidateIDs: [],
            searchQueries: ["gift idea"]
        )
        #expect(MissionCategory.classify(vague) == .generic)
    }

    // MARK: Chip integrity

    @Test("Every chip in every category routes into an actionable, search-free directive")
    func everyChipIsActionable() {
        for category in MissionCategory.allCases {
            let chips = category.chips
            #expect((2...4).contains(chips.count), "category: \(category)")
            // Ids are unique within a set (they back the ForEach + a11y identifier).
            #expect(Set(chips.map(\.id)).count == chips.count, "duplicate id in \(category)")
            // Every category offers the price lever.
            #expect(chips.contains { $0.refinementText.contains("cheaper") }, "no price chip in \(category)")

            for chip in chips {
                let directive = RuleBasedRefinementInterpreter.heuristicDirective(for: chip.refinementText)
                #expect(directive.isActionable, "chip '\(chip.label)' in \(category) did nothing")
                // A chip re-shapes the existing deck; it never fires a catalog search.
                #expect(directive.addQueries.isEmpty, "chip '\(chip.label)' in \(category) searched")
            }
        }
    }

    @Test("The mission's chips read tea-appropriate, not gear-oriented")
    func beverageChipsAreNotGear() {
        let labels = MissionCategory.beverages.chips.map(\.label)
        #expect(!labels.contains("Warmer"))
        #expect(!labels.contains("More durable"))
        #expect(labels.contains("Caffeine-free"))
    }

    @Test("The rule-based suggester returns the classified category's chips")
    func floorReturnsCategoryChips() {
        #expect(RuleBasedRefineChipSuggester.chips(for: SeedData.coffee) == MissionCategory.beverages.chips)
    }

    // MARK: Reconcile (the pure guarantee behind the model call)

    @Test("A clean draft is zipped, trimmed, deduped, and capped at four")
    func reconcileCleansDraft() {
        let floor = MissionCategory.generic.chips
        let draft = RefineChipDraft(
            labels: ["Cheaper", " Organic ", "Organic", "Bolder", "Decaf"],  // dupe + a 5th
            refinementTexts: ["make it cheaper", "organic please", "dupe", "bolder flavor", "decaf only"]
        )
        let chips = AppleFoundationRefineChipSuggester.reconcile(draft: draft, floor: floor)
        #expect(chips.count == 4)                       // capped
        #expect(chips.map(\.label) == ["Cheaper", "Organic", "Bolder", "Decaf"])  // trimmed + deduped
        #expect(chips[1].refinementText == "organic please")
    }

    @Test("A price lever is grafted back when the model drops it (as the on-device model does)")
    func reconcileGuaranteesPriceLever() {
        let floor = MissionCategory.apparel.chips  // its price chip is "Cheaper"

        // Three category-fit chips, no price lever — the exact shape seen on the hike sim run.
        let noPrice = RefineChipDraft(
            labels: ["Rainy", "Warm", "Natural"],
            refinementTexts: ["built for rain", "warmer materials", "natural fibers"]
        )
        let grafted = AppleFoundationRefineChipSuggester.reconcile(draft: noPrice, floor: floor)
        #expect(grafted.contains { AppleFoundationRefineChipSuggester.isPriceLever($0) })
        #expect(grafted.map(\.label) == ["Rainy", "Warm", "Natural", "Cheaper"])

        // A full four-chip draft with no price lever drops its weakest tail to keep the row short.
        let fullNoPrice = RefineChipDraft(
            labels: ["Rainy", "Warm", "Natural", "Lighter"],
            refinementTexts: ["built for rain", "warmer materials", "natural fibers", "packs smaller"]
        )
        let capped = AppleFoundationRefineChipSuggester.reconcile(draft: fullNoPrice, floor: floor)
        #expect(capped.count == 4)
        #expect(capped.last?.label == "Cheaper")

        // A draft that kept a price lever is untouched (no duplicate Cheaper).
        let withPrice = RefineChipDraft(
            labels: ["Warm", "Cheaper"],
            refinementTexts: ["warmer materials", "make it cheaper"]
        )
        let kept = AppleFoundationRefineChipSuggester.reconcile(draft: withPrice, floor: floor)
        #expect(kept.map(\.label) == ["Warm", "Cheaper"])
    }

    @Test("A thin draft falls back to the deterministic floor instead of one lonely chip")
    func reconcileThinDraftFallsBack() {
        let floor = MissionCategory.beverages.chips
        let thin = RefineChipDraft(labels: ["Cheaper"], refinementTexts: ["make it cheaper"])
        #expect(AppleFoundationRefineChipSuggester.reconcile(draft: thin, floor: floor) == floor)

        // Blank entries drop out, taking the count below the floor threshold.
        let blanks = RefineChipDraft(labels: ["  ", "Organic"], refinementTexts: ["ignored", "   "])
        #expect(AppleFoundationRefineChipSuggester.reconcile(draft: blanks, floor: floor) == floor)
    }

    @Test("Mismatched array lengths zip to the shorter side without crashing")
    func reconcileMismatchedArrays() {
        let floor = MissionCategory.generic.chips
        let draft = RefineChipDraft(
            labels: ["Cheaper", "Organic", "Bolder"],
            refinementTexts: ["make it cheaper", "organic"]  // one short
        )
        let chips = AppleFoundationRefineChipSuggester.reconcile(draft: draft, floor: floor)
        #expect(chips.map(\.label) == ["Cheaper", "Organic"])
    }

    @Test("An all-caps model label is softened to the floor's sentence case")
    func reconcileNormalizesShoutyLabels() {
        let floor = MissionCategory.apparel.chips
        let shouty = RefineChipDraft(
            labels: ["MERINO", "NATURAL", "Caffeine-free"],
            refinementTexts: ["merino wool", "natural fibers", "less caffeine"]
        )
        let chips = AppleFoundationRefineChipSuggester.reconcile(draft: shouty, floor: floor)
        #expect(chips.map(\.label).prefix(3) == ["Merino", "Natural", "Caffeine-free"])
    }

    @Test("Slug makes an a11y-safe id from any label")
    func slugIsSafe() {
        #expect(RefineChip.slug("Caffeine-free") == "caffeine-free")
        #expect(RefineChip.slug("More durable") == "more-durable")
        #expect(RefineChip.slug("  Loose  Leaf!! ") == "loose-leaf")
        #expect(RefineChip.slug("") == "chip")
    }
}
