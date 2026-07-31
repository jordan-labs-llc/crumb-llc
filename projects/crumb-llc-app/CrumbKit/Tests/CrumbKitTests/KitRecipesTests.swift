import Testing
import Foundation
@testable import CrumbKit

/// The recipe table is the thing that makes a mission a kit rather than one keyword search, so its
/// guarantees are structural: every row has to be shoppable, and matching has to be conservative
/// enough that an unrelated goal never inherits six wrong parts.
@Suite("Kit recipes")
struct KitRecipesTests {

    // MARK: - Every row has to be usable

    @Test("Every recipe is shoppable: capped, non-empty, and free of category words")
    func everyRecipeIsWellFormed() {
        // The words the model produced that no catalog search resolves — "Outerwear", "Hydration",
        // "Sun protection". The whole point of a table is that it never emits these.
        let categoryWords: Set<String> = [
            "footwear", "outerwear", "layer", "layers", "hydration", "apparel", "clothing",
            "accessories", "accessory", "gear", "equipment", "nutrition", "audio", "lighting",
            "electronics", "supplies", "essentials", "storage", "seating", "extras", "toppings",
        ]
        for recipe in KitRecipes.all {
            #expect(!recipe.parts.isEmpty, "\(recipe.id) has no parts")
            #expect(recipe.parts.count <= RuleBasedMissionPlanner.maxParts, "\(recipe.id) exceeds maxParts")
            #expect(!recipe.cues.isEmpty, "\(recipe.id) has no cues")
            #expect(!recipe.assumption.isEmpty, "\(recipe.id) states no assumption")

            for part in recipe.parts {
                #expect(!part.label.isEmpty, "\(recipe.id) has an unlabelled part")
                #expect(!part.query.isEmpty, "\(recipe.id)/\(part.label) has no query")
                #expect(
                    !categoryWords.contains(part.label.lowercased()),
                    "\(recipe.id)/\(part.label) is a category, not a product"
                )
                // A query is what you'd type into a shop's search box.
                let words = part.query.split(separator: " ")
                #expect((1...5).contains(words.count), "\(recipe.id)/\(part.label) query isn't keywords")
                #expect(
                    part.query == part.query.lowercased(),
                    "\(recipe.id)/\(part.label) query should be lowercase keywords"
                )
                #expect(
                    !part.query.contains(where: { ",.;:!?\"'()/".contains($0) }),
                    "\(recipe.id)/\(part.label) query carries punctuation"
                )
            }

            let queries = recipe.parts.map(\.query)
            #expect(Set(queries).count == queries.count, "\(recipe.id) repeats a query")
        }
    }

    @Test("Recipe ids are unique")
    func idsAreUnique() {
        let ids = KitRecipes.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Matching

    @Test("The goals the study ran all decompose")
    func measuredGoalsDecompose() throws {
        // Each of these was measured producing a one-part keyword search before the table existed.
        // "set up a home coffee bar" returned $698 of coffee-bar furniture and no coffee.
        let expected: [(String, String)] = [
            ("set up a home coffee bar", "coffee-bar"),
            ("pack me for a rainy weekend hike", "rain-hike"),
            ("outfit a home office for video calls", "video-call-office"),
            ("premium lacrosse gear", "lacrosse"),
            ("everything for taco night for eight people", "taco-night"),
            ("new baby nursery essentials", "nursery"),
            ("get me ready for my first marathon", "running"),
            ("everything for a home bar cart", "bar-cart"),
        ]
        for (goal, id) in expected {
            let recipe = try #require(KitRecipes.recipe(for: goal), "no recipe for “\(goal)”")
            #expect(recipe.id == id, "“\(goal)” matched \(recipe.id), expected \(id)")
        }
    }

    @Test("A single item is never expanded into a kit")
    func singleItemGoalsDoNotMatch() {
        // The opposite failure to under-decomposition, and the more annoying one: asking for one
        // thing and being handed a six-part shopping list.
        for goal in [
            "a cast iron skillet",
            "premium jasmine tea",
            "a pour-over kettle with a gooseneck spout",
            "a warm winter coat for a rainy commute",
            "lacrosse stick",
            "running shoes",
            "a yoga mat",
            "espresso machine",
        ] {
            #expect(KitRecipes.recipe(for: goal) == nil, "“\(goal)” was wrongly expanded")
        }
    }

    @Test("A domain word inside an unrelated product doesn't drag in its kit")
    func nearMissesDoNotMatch() {
        // The bare-noun cues ("coffee", "tea", "pool") were removed for exactly these: each one is a
        // real goal that shares a word with a recipe and wants nothing to do with it.
        for goal in [
            "set up a coffee table",           // coffee-bar
            "everything for a pool table",     // swimming
            "a tea towel set",                 // tea-bar
            "set up a bar stool",              // bar-cart
        ] {
            let recipe = KitRecipes.recipe(for: goal)
            #expect(
                recipe == nil || !["coffee-bar", "swimming", "tea-bar", "bar-cart"].contains(recipe!.id),
                "“\(goal)” matched \(recipe!.id)"
            )
        }
    }

    @Test("The longest matching cue wins")
    func longestCueWins() throws {
        // "espresso bar" and "espresso" both match the espresso recipe, but "coffee bar" inside
        // "home coffee bar" must not lose to a shorter cue elsewhere.
        let espresso = try #require(KitRecipes.recipe(for: "set up an espresso bar"))
        #expect(espresso.id == "espresso-bar")
        let coffee = try #require(KitRecipes.recipe(for: "set up a coffee corner"))
        #expect(coffee.id == "coffee-bar")
    }

    @Test("Kit intent gates every domain, uniformly")
    func kitIntentGating() {
        // A bare domain noun never expands: "lacrosse" is also a lone stick, "nursery" is also a
        // lamp, "running" is also a pair of shoes. Only an actual request for a *set* fires a recipe.
        #expect(KitRecipes.recipe(for: "lacrosse") == nil)
        #expect(KitRecipes.recipe(for: "nursery") == nil)
        #expect(KitRecipes.recipe(for: "running") == nil)
        #expect(KitRecipes.recipe(for: "premium lacrosse gear")?.id == "lacrosse")
        #expect(KitRecipes.recipe(for: "nursery essentials")?.id == "nursery")
        #expect(KitRecipes.recipe(for: "training for a marathon")?.id == "running")
    }

    @Test("The phrasings that were measured falling through now register as kit intent")
    func widenedKitIntentCues() {
        // Both of these scored at or near zero coverage before the gate was widened: the hike
        // returned one part (17%) and taco night returned one part (0%), while the recipes that
        // answer them sat unused.
        #expect(RuleBasedMissionPlanner.mentionsKitIntent("pack me for a rainy weekend hike"))
        #expect(RuleBasedMissionPlanner.mentionsKitIntent("everything for taco night for eight people"))
        #expect(RuleBasedMissionPlanner.mentionsKitIntent("get me ready for my first marathon"))
        // And it still says no to a plain product.
        #expect(RuleBasedMissionPlanner.mentionsKitIntent("a cast iron skillet") == false)
        #expect(RuleBasedMissionPlanner.mentionsKitIntent("premium jasmine tea") == false)
    }

    // MARK: - Through the planner

    @Test("A recognized kit reaches the mission as a real multi-part plan")
    func plannerProducesMultiPartTask() async throws {
        let planner = DirectMissionPlanner()          // heuristic triage — no model needed
        let planned = await planner.plan(goal: "set up a home coffee bar", profile: SeedData.defaultTasteProfile)
        let task = try #require(planned.task)

        #expect(task.plan.count == 6)
        #expect(task.isSingleItem == false)
        #expect(task.searchQueries.count == task.plan.count, "each part needs its own query")
        // The failure this whole phase exists to fix: the mission searched the literal goal and came
        // back with coffee-bar furniture.
        #expect(task.searchQueries.contains { $0.contains("coffee maker") })
        #expect(task.searchQueries.contains { $0.contains("grinder") })
        #expect(task.searchQueries.allSatisfy { $0 != "home coffee bar" })
        // The assumption is stated so it can be corrected.
        #expect(task.curatorNote.contains("Assuming"))
    }

    @Test("An unrecognized goal still gets a searchable single-part mission")
    func unrecognizedGoalStillPlans() async throws {
        let planner = DirectMissionPlanner()
        let planned = await planner.plan(goal: "a cast iron skillet", profile: SeedData.defaultTasteProfile)
        let task = try #require(planned.task)
        #expect(task.plan.count == 1)
    }
}

/// The compound-word gap in `KitCompleteness.partCovered`, which decided how a decomposed mission
/// walks its own checklist.
@Suite("Kit completeness compounds")
struct KitCompletenessCompoundTests {

    private func tokens(_ names: [String]) -> [Set<String>] {
        names.map { RuleBasedRelevanceGate.tokens($0) }
    }

    @Test("A closed compound covers the two-word part")
    func closedCompoundCoversPart() {
        // Measured: with part-aware ordering in place, a live "home coffee bar" run offered five
        // pour-over coffeemakers in a row, because keeping "1-Cup Porcelain Pour-Over Coffeemaker"
        // never marked the "Coffee maker" part covered.
        #expect(KitCompleteness.partCovered("Coffee maker", by: tokens(["1-Cup Porcelain Pour-Over Coffeemaker"])))
        #expect(KitCompleteness.partCovered("Coffee maker", by: tokens(["Original 8-Cup Pour-Over Coffee Maker"])))
        #expect(KitCompleteness.partCovered("Tea pot", by: tokens(["Glass Teapot with Infuser"])))
    }

    @Test("The compound match doesn't cover an unrelated part")
    func compoundDoesNotOvermatch() {
        #expect(KitCompleteness.partCovered("Coffee maker", by: tokens(["Baratza Encore Coffee Grinder"])) == false)
        #expect(KitCompleteness.partCovered("Grinder", by: tokens(["Melitta Cone Filter Paper"])) == false)
        #expect(KitCompleteness.partCovered("Kettle", by: tokens(["Ceramic Coffee Mug"])) == false)
    }

    @Test("A decomposed kit walks to the next uncovered part once its anchor is kept")
    func deckAdvancesPastACoveredPart() {
        let plan = ["Coffee maker", "Grinder", "Kettle"]
        let kept = tokens(["1-Cup Porcelain Pour-Over Coffeemaker"])
        let missing = plan.filter { !KitCompleteness.partCovered($0, by: kept) }
        #expect(missing == ["Grinder", "Kettle"])
    }
}

/// The singular/plural half of the same gap: a checklist and a catalog rarely agree on number.
@Suite("Kit completeness number agreement")
struct KitCompletenessNumberTests {

    private func tokens(_ names: [String]) -> [Set<String>] {
        names.map { RuleBasedRelevanceGate.tokens($0) }
    }

    @Test("A plural part is covered by a singular product name, and the reverse")
    func numberDisagreementStillCovers() {
        // Measured: the "Coffee beans" part was offered twice in a live run, because keeping
        // "Lavazza Expert Plus Aroma Top Espresso Whole Bean Coffee" never covered it.
        #expect(KitCompleteness.partCovered("Coffee beans", by: tokens(["Lavazza Whole Bean Coffee"])))
        #expect(KitCompleteness.partCovered("Mugs", by: tokens(["Ceramic Coffee Mug"])))
        #expect(KitCompleteness.partCovered("Filters", by: tokens(["V60 Paper Filter for 02 Dripper"])))
        #expect(KitCompleteness.partCovered("Glove", by: tokens(["Lacrosse Gloves"])))
    }

    @Test("Singularizing never merges genuinely different shelves")
    func stemmingDoesNotOvermatch() {
        #expect(KitCompleteness.partCovered("Coffee beans", by: tokens(["Baratza Encore Grinder"])) == false)
        #expect(KitCompleteness.partCovered("Mugs", by: tokens(["Gooseneck Kettle"])) == false)
        // A double "s" is not a plural: these words must survive intact.
        #expect(KitCompleteness.singularized("glass") == "glass")
        #expect(KitCompleteness.singularized("press") == "press")
        #expect(KitCompleteness.singularized("gas") == "gas")       // too short to strip
        #expect(KitCompleteness.singularized("beans") == "bean")
    }

    @Test("A six-part coffee bar closes out in six keeps")
    func fullKitCloses() {
        let plan = ["Coffee maker", "Grinder", "Kettle", "Coffee beans", "Filters", "Mugs"]
        let kept = [
            "1-Cup Porcelain Pour-Over Coffeemaker",
            "Baratza Encore Coffee Grinder",
            "Stovetop Gooseneck Kettle",
            "Lavazza Whole Bean Coffee",
            "V60 Paper Filter for 02 Dripper",
            "Ceramic Coffee Mug",
        ]
        let missing = plan.filter { !KitCompleteness.partCovered($0, by: tokens(kept)) }
        #expect(missing.isEmpty, "still uncovered: \(missing)")
    }
}
