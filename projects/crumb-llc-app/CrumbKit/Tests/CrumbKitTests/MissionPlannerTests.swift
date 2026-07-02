import Testing
import Foundation
@testable import CrumbKit

/// The deterministic guarantees behind the planning seam. The model call itself stays
/// untested (unavailable on CI/sim, exactly like the curator/extractor) — but the pure
/// reconcile (`mission(from:goal:tier:)`), the rule-based floor, and the recents merge are
/// exercised exhaustively here.
@Suite("MissionPlanner")
struct MissionPlannerTests {

    // MARK: Rule-based floor (the always-on sim/CI planner)

    @Test("A shoppable goal becomes a one-part mission whose query is the cleaned goal")
    func ruleBasedShoppable() async {
        let planned = await RuleBasedMissionPlanner().plan(
            goal: "  set up my pour-over corner  ", profile: SeedData.defaultTasteProfile
        )
        let task = try? #require(planned.task)
        #expect(planned.isShoppable)
        #expect(task?.searchQueries == ["set up my pour-over corner"]) // single generic query
        #expect(task?.plan.count == 1)
        #expect(task?.title == "Set up my pour-over corner")           // title-cased
        #expect(planned.tier == .ruleBased(nil))                       // chosen default → quiet UI
        #expect(planned.tier.fallbackNote == nil)
    }

    // MARK: Single-product mode (#56)

    @Test("isSingleItem: a concrete product goal is single; outfitting a space/activity is a kit")
    func isSingleItemHeuristic() {
        // Single specific products.
        for goal in ["premium jasmine tea", "a cast iron skillet", "wool beanie", "gooseneck kettle"] {
            #expect(RuleBasedMissionPlanner.isSingleItem(goal: goal), "\(goal) should be single-item")
        }
        // Outfitting a space or activity, or a "gear/equipment" goal — a multi-part kit.
        for goal in [
            "set up my pour-over corner", "pack me for a rainy weekend hike",
            "make my desk feel calm", "cozy reading nook", "everything for a new nursery",
            // #65: "<X> gear/equipment/supplies" is a complete kit, not a single item.
            "buying premium lacrosse gear", "premium lacrosse gear", "ski equipment",
            "camping gear", "art supplies", "travel essentials",
        ] {
            #expect(!RuleBasedMissionPlanner.isSingleItem(goal: goal), "\(goal) should be a kit")
        }
    }

    @Test("The rule-based floor tags a single-product goal, and leaves a kit goal untagged")
    func ruleBasedSetsSingleItem() async {
        let profile = SeedData.defaultTasteProfile
        let single = await RuleBasedMissionPlanner().plan(goal: "premium jasmine tea", profile: profile)
        #expect(single.task?.isSingleItem == true)
        let kit = await RuleBasedMissionPlanner().plan(goal: "set up my pour-over corner", profile: profile)
        #expect(kit.task?.isSingleItem == false)
    }

    @Test("Seed missions are multi-part kits, never single-product")
    func seedMissionsAreKits() {
        for task in SeedData.missions {
            #expect(!task.isSingleItem, "\(task.id) should default to kit framing")
        }
    }

    @Test("ShoppingTask round-trips isSingleItem, and legacy snapshots without the key decode as false")
    func shoppingTaskCodableBackCompat() throws {
        let task = RuleBasedMissionPlanner.makeTask(
            goal: "premium jasmine tea", title: "Premium Jasmine Tea", subtitle: "s", note: "n",
            parts: [(label: "Premium Jasmine Tea", query: "premium jasmine tea")], isSingleItem: true
        )
        let roundTripped = try JSONDecoder().decode(ShoppingTask.self, from: JSONEncoder().encode(task))
        #expect(roundTripped.isSingleItem == true)
        #expect(roundTripped == task)

        // A snapshot persisted before the field existed omits the key entirely → decodes as false.
        let legacy = """
        {"id":"goal.x","title":"X","subtitle":"s","plan":["X"],"curatorNote":"n","accentHex":1,"candidateIDs":[],"searchQueries":["x"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ShoppingTask.self, from: legacy)
        #expect(decoded.isSingleItem == false)
    }

    @Test("An empty or too-short goal is not shoppable and carries a decline message")
    func ruleBasedEmptyDeclines() async {
        for goal in ["", "   ", "x"] {
            let planned = await RuleBasedMissionPlanner().plan(goal: goal, profile: SeedData.defaultTasteProfile)
            #expect(planned.task == nil, "goal: \(goal)")
            #expect(planned.decline == RuleBasedMissionPlanner.declineMessage)
            #expect(!planned.isShoppable)
        }
    }

    @Test("A bare question is treated as asking, not shopping")
    func ruleBasedQuestionDeclines() {
        #expect(!RuleBasedMissionPlanner.isShoppable("what's the weather?"))
        #expect(!RuleBasedMissionPlanner.isShoppable("how do I tie a tie?"))
        // A shopping request that merely contains a question mark elsewhere still shops.
        #expect(RuleBasedMissionPlanner.isShoppable("gift for mom, what's nice?"))
        #expect(RuleBasedMissionPlanner.isShoppable("set up my pour-over corner"))
    }

    @Test("A degraded AI planner reports its reason so the UI shows an honest note")
    func ruleBasedFallbackReason() {
        let planned = RuleBasedMissionPlanner.plan(goal: "warm winter layers", reason: .offlineOrError)
        #expect(planned.isShoppable)
        #expect(planned.tier == .ruleBased(.offlineOrError))
        #expect(planned.tier.fallbackNote != nil)
    }

    @Test("The mission id is stable and slugified from the goal")
    func missionIDStable() {
        let a = RuleBasedMissionPlanner.missionID(for: "Set up my Pour-Over corner!!")
        let b = RuleBasedMissionPlanner.missionID(for: "  set up my pour-over corner  ")
        #expect(a == b)                              // case/punct/space-insensitive
        #expect(a == "goal.set-up-my-pour-over-corner")
        #expect(RuleBasedMissionPlanner.missionID(for: "!!!") == "goal.mission") // no slug → safe default
    }

    @Test("The accent is deterministic across calls for the same goal")
    func accentDeterministic() {
        #expect(
            RuleBasedMissionPlanner.accentHex(for: "rainy hike")
                == RuleBasedMissionPlanner.accentHex(for: "Rainy Hike")
        )
    }

    // MARK: Sports player-kit expansion (#68)

    @Test("A lacrosse gear goal expands into a multi-part player kit with a stated assumption")
    func sportsKitExpandsLacrosse() async {
        let planned = await RuleBasedMissionPlanner().plan(goal: "buying premium lacrosse gear",
                                                           profile: SeedData.defaultTasteProfile)
        let task = planned.task
        #expect(task?.isSingleItem == false)                       // a kit, not a lone product
        #expect((task?.plan.count ?? 0) >= 4)                      // several concrete gear parts
        #expect(task?.plan.contains("Helmet") == true)
        #expect(task?.plan.contains("Gloves") == true)
        // Search queries are lacrosse-specific so the broker finds real player gear.
        #expect(task?.searchQueries.contains("lacrosse helmet") == true)
        // The curator note states the editable default assumption.
        #expect(task?.curatorNote.localizedCaseInsensitiveContains("field player") == true)
    }

    @Test("sportsKit fires on a gear/kit intent but not on a single-piece goal")
    func sportsKitGating() {
        #expect(RuleBasedMissionPlanner.sportsKit(for: "premium lacrosse gear") != nil)
        #expect(RuleBasedMissionPlanner.sportsKit(for: "high school lacrosse equipment") != nil)
        // A single piece — no kit intent — is left to the normal single-query path.
        #expect(RuleBasedMissionPlanner.sportsKit(for: "lacrosse stick") == nil)
        #expect(RuleBasedMissionPlanner.sportsKit(for: "lacrosse ball") == nil)
        // A non-sports goal is untouched.
        #expect(RuleBasedMissionPlanner.sportsKit(for: "premium jasmine tea") == nil)
    }

    @Test("The model planner reconciles an under-decomposed lacrosse draft to the player-kit floor (#68)")
    func reconcileUnderDecomposedSportsKit() {
        // The observed live failure: the model framed "premium lacrosse gear" as a single "stick".
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: true, title: "Premium lacrosse gear",
            subtitle: "For the season", note: "A steady pick.",
            parts: [PlanPartDraft(label: "Lacrosse stick", query: "lacrosse stick")],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "buying premium lacrosse gear", tier: .onDevice).task
        #expect(task?.isSingleItem == false)                       // reconciled to a kit
        #expect((task?.plan.count ?? 0) >= 4)                      // real safety/fit parts
        #expect(task?.plan.contains("Helmet") == true)
        #expect(task?.curatorNote.localizedCaseInsensitiveContains("field player") == true)
    }

    @Test("A model draft that already decomposes a kit well is left as the model wrote it")
    func reconcileKeepsGoodModelKit() {
        // Two solid parts, kit framing — no under-decomposition, so no sports-kit override.
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: false, title: "Lacrosse gear",
            subtitle: "", note: "Model note.",
            parts: [
                PlanPartDraft(label: "Attack shaft", query: "lacrosse attack shaft"),
                PlanPartDraft(label: "Head", query: "lacrosse head"),
            ],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "lacrosse gear", tier: .onDevice).task
        #expect(task?.plan == ["Attack shaft", "Head"])            // the model's own decomposition
        #expect(task?.curatorNote == "Model note.")
    }

    // MARK: Reconcile (the pure fold of a model draft → mission)

    @Test("A full valid draft folds into a clean, searchable mission")
    func reconcileFull() {
        let draft = MissionDraft(
            isShoppable: true,
            title: "Set up my pour-over corner",
            subtitle: "Slower mornings",
            note: "Here's where I'd start.",
            parts: [
                PlanPartDraft(label: "Gooseneck kettle", query: "gooseneck kettle"),
                PlanPartDraft(label: "Burr grinder", query: "burr coffee grinder"),
            ],
            decline: ""
        )
        let planned = AppleFoundationMissionPlanner.mission(from: draft, goal: "pour over setup", tier: .onDevice)
        let task = planned.task

        #expect(task?.title == "Set up my pour-over corner")
        #expect(task?.subtitle == "Slower mornings")
        #expect(task?.curatorNote == "Here's where I'd start.")
        #expect(task?.plan == ["Gooseneck kettle", "Burr grinder"])
        #expect(task?.searchQueries == ["gooseneck kettle", "burr coffee grinder"])
        #expect(planned.tier == .onDevice)            // proven tier preserved
    }

    @Test("Blank title/subtitle/note in the draft backfill from deterministic defaults")
    func reconcileBackfillsBlankFields() {
        let draft = MissionDraft(
            isShoppable: true, title: "  ", subtitle: "", note: "  ",
            parts: [PlanPartDraft(label: "Rain shell", query: "rain jacket")],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "rainy hike kit", tier: .onDevice).task
        #expect(task?.title == "Rainy hike kit")                      // from goal
        #expect(task?.subtitle == RuleBasedMissionPlanner.defaultSubtitle)
        #expect(task?.curatorNote.isEmpty == false)                  // synthesized note
    }

    @Test("Garbage parts are dropped, half-filled parts repaired, duplicates collapsed, count capped")
    func reconcileCleansParts() {
        var parts = [
            PlanPartDraft(label: "  ", query: "  "),                  // empty → dropped
            PlanPartDraft(label: "Kettle", query: ""),               // query borrows label
            PlanPartDraft(label: "", query: "burr grinder"),         // label borrows query
            PlanPartDraft(label: "Kettle again", query: "Kettle"),   // dup query (case-insensitive) → dropped
        ]
        // Push well past the cap with unique queries to prove the cap.
        for i in 0..<10 { parts.append(PlanPartDraft(label: "Item \(i)", query: "query \(i)")) }

        let cleaned = AppleFoundationMissionPlanner.cleanParts(parts)
        #expect(cleaned.count == RuleBasedMissionPlanner.maxParts)   // capped at 6
        #expect(cleaned[0] == (label: "Kettle", query: "Kettle"))    // empty query borrows the label (case preserved)
        #expect(cleaned[1] == (label: "burr grinder", query: "burr grinder")) // empty label borrows the query
        // No duplicate queries survive.
        let queries = cleaned.map { $0.query.lowercased() }
        #expect(Set(queries).count == queries.count)
    }

    @Test("A shoppable draft with no usable parts degrades to the single-query plan")
    func reconcileEmptyPartsFallsBackToSingleQuery() {
        let draft = MissionDraft(
            isShoppable: true, title: "", subtitle: "", note: "",
            parts: [PlanPartDraft(label: "", query: "")],            // nothing usable
            decline: ""
        )
        let planned = AppleFoundationMissionPlanner.mission(from: draft, goal: "cozy reading nook", tier: .onDevice)
        let task = planned.task
        #expect(task?.searchQueries == ["cozy reading nook"])        // same as the rule-based floor
        #expect(task?.plan.count == 1)
        #expect(planned.tier == .onDevice)                           // tier still reported as proven
    }

    @Test("A single-item draft collapses to exactly one part, even if the model over-produced")
    func reconcileSingleItemStaysTight() {
        // The model flagged a single item but padded the plan with accessories anyway. The pure
        // reconcile must keep only the core (first) part, so tightness never rides on the model.
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: true, title: "Premium jasmine tea", subtitle: "", note: "",
            parts: [
                PlanPartDraft(label: "Premium jasmine tea", query: "premium jasmine tea"),
                PlanPartDraft(label: "Teapot", query: "glass teapot"),          // accessory — must be dropped
                PlanPartDraft(label: "Tea strainer", query: "tea strainer"),    // accessory — must be dropped
            ],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "buy premium jasmine tea", tier: .onDevice).task
        #expect(task?.plan.count == 1)
        #expect(task?.searchQueries == ["premium jasmine tea"])   // the core item only, no accessories
    }

    @Test("Direct product goals override model drift into teaware accessories (#84)")
    func reconcileDirectProductOverridesAccessoryDrift() {
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: false,
            title: "Premium jasmine tea",
            subtitle: "Three vessels",
            note: "You'll find three vessels for a steady tea ritual.",
            parts: [
                PlanPartDraft(label: "Teapot", query: "glass teapot"),
                PlanPartDraft(label: "Tea strainer", query: "tea strainer"),
            ],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "premium jasmine tea", tier: .onDevice).task

        #expect(task?.isSingleItem == true)
        #expect(task?.plan == ["Premium jasmine tea"])
        #expect(task?.searchQueries == ["premium jasmine tea"])
        #expect(task?.subtitle == RuleBasedMissionPlanner.defaultSubtitle)
        #expect(task?.curatorNote.localizedCaseInsensitiveContains("vessels") == false)
    }

    @Test("Direct product goals keep a visible core label even when the model query is on-goal (#84)")
    func reconcileDirectProductRepairsGenericVisibleLabel() {
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: true,
            title: "premium jasmine tea",
            subtitle: "a quiet moment with leaves",
            note: "A single leaf, steady and enduring.",
            parts: [PlanPartDraft(label: "tea leaves", query: "premium jasmine tea")],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "premium jasmine tea", tier: .onDevice).task

        #expect(task?.plan == ["Premium jasmine tea"])
        #expect(task?.searchQueries == ["premium jasmine tea"])
        #expect(task?.subtitle == RuleBasedMissionPlanner.defaultSubtitle)
        #expect(task?.curatorNote.localizedCaseInsensitiveContains("leaf") == false)
    }

    @Test("Direct product override covers tea and beverage categories without blocking setup queries (#84)")
    func reconcileDirectProductOverrideExamples() {
        let jasminePearls = MissionDraft(
            isShoppable: true, isSingleItem: false,
            title: "Jasmine pearls", subtitle: "", note: "",
            parts: [PlanPartDraft(label: "Pearl tea infuser", query: "tea infuser")],
            decline: ""
        )
        let pearlsTask = AppleFoundationMissionPlanner.mission(from: jasminePearls, goal: "jasmine pearls", tier: .onDevice).task
        #expect(pearlsTask?.plan == ["Jasmine pearls"])
        #expect(pearlsTask?.searchQueries == ["jasmine pearls"])
        #expect(pearlsTask?.isSingleItem == true)

        let matchaPowder = MissionDraft(
            isShoppable: true, isSingleItem: false,
            title: "Matcha powder", subtitle: "", note: "",
            parts: [PlanPartDraft(label: "Matcha whisk", query: "matcha whisk")],
            decline: ""
        )
        let matchaTask = AppleFoundationMissionPlanner.mission(from: matchaPowder, goal: "matcha powder", tier: .onDevice).task
        #expect(matchaTask?.plan == ["Matcha powder"])
        #expect(matchaTask?.searchQueries == ["matcha powder"])
        #expect(matchaTask?.isSingleItem == true)

        let setup = MissionDraft(
            isShoppable: true, isSingleItem: false,
            title: "Tea brewing setup", subtitle: "", note: "",
            parts: [
                PlanPartDraft(label: "Teapot", query: "teapot"),
                PlanPartDraft(label: "Infuser", query: "tea infuser"),
            ],
            decline: ""
        )
        let setupTask = AppleFoundationMissionPlanner.mission(from: setup, goal: "tea brewing setup", tier: .onDevice).task
        #expect(setupTask?.isSingleItem == false)
        #expect(setupTask?.plan == ["Teapot", "Infuser"])
    }

    @Test("A broad draft keeps its several complementary parts")
    func reconcileBroadKeepsParts() {
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: false, title: "Set up my pour-over corner", subtitle: "", note: "",
            parts: [
                PlanPartDraft(label: "Gooseneck kettle", query: "gooseneck kettle"),
                PlanPartDraft(label: "Burr grinder", query: "burr grinder"),
                PlanPartDraft(label: "Pour-over dripper", query: "pour over dripper"),
            ],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "set up my pour-over corner", tier: .onDevice).task
        #expect(task?.plan.count == 3)   // a broad goal is not collapsed
    }

    // MARK: Exemplar-leak guard (#23 — a seed subtitle must not leak onto an unrelated goal)

    @Test("A leaked coffee exemplar (title/subtitle/note) is dropped for an unrelated tea goal")
    func reconcileDropsLeakedExemplar() {
        // The bug: for "premium jasmine tea" the model parroted the coffee seed's metadata verbatim.
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: true,
            title: SeedData.coffee.title,          // "Set up my pour-over corner"
            subtitle: SeedData.coffee.subtitle,    // "Slower mornings · better cup"
            note: SeedData.coffee.curatorNote,
            parts: [PlanPartDraft(label: "Premium jasmine tea", query: "premium jasmine tea")],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "premium jasmine tea", tier: .onDevice).task

        #expect(task?.subtitle != SeedData.coffee.subtitle)                 // the leak is gone
        #expect(task?.subtitle == RuleBasedMissionPlanner.defaultSubtitle)  // → deterministic default
        #expect(task?.title != SeedData.coffee.title)                       // title leak gone too
        #expect(task?.title == "Premium jasmine tea")                       // → goal-derived
        #expect(task?.curatorNote != SeedData.coffee.curatorNote)           // note leak gone
    }

    @Test("A seed-matching field that genuinely fits the goal is kept (not a leak)")
    func reconcileKeepsOnGoalExemplar() {
        // "Set up my pour-over corner" IS the right title for a pour-over goal — it shares words
        // with the goal, so the guard must keep it rather than treat it as a leak.
        let draft = MissionDraft(
            isShoppable: true, isSingleItem: false,
            title: SeedData.coffee.title, subtitle: "Slow mornings, better pour-over",
            note: "A calm corner for a better cup.",
            parts: [PlanPartDraft(label: "Gooseneck kettle", query: "gooseneck kettle")],
            decline: ""
        )
        let task = AppleFoundationMissionPlanner.mission(from: draft, goal: "set up my pour-over corner", tier: .onDevice).task
        #expect(task?.title == SeedData.coffee.title)   // shares "pour over" with the goal → kept
    }

    @Test("isLeakedExemplar: a seed phrase off-topic for the goal leaks; on-topic or novel does not")
    func isLeakedExemplarPure() {
        // Off-topic copy of a seed subtitle → a leak.
        #expect(AppleFoundationMissionPlanner.isLeakedExemplar(SeedData.coffee.subtitle, goal: "premium jasmine tea"))
        #expect(AppleFoundationMissionPlanner.isLeakedExemplar(SeedData.hike.subtitle, goal: "a birthday gift for mom"))
        // A seed title that shares a word with the goal is legitimate, not a leak.
        #expect(!AppleFoundationMissionPlanner.isLeakedExemplar(SeedData.coffee.title, goal: "pour over setup"))
        // Anything the planner actually wrote for the goal (not a seed phrase) is never a leak.
        #expect(!AppleFoundationMissionPlanner.isLeakedExemplar("A fragrant jasmine ritual", goal: "premium jasmine tea"))
        // Punctuation/casing variations of a seed phrase still match (normalized).
        #expect(AppleFoundationMissionPlanner.isLeakedExemplar("slower mornings, better cup!", goal: "premium jasmine tea"))
    }

    @Test("A not-shoppable draft yields no task and a decline message")
    func reconcileNotShoppable() {
        let withMsg = MissionDraft(
            isShoppable: false, title: "", subtitle: "", note: "", parts: [],
            decline: "I shop for things — try a goal."
        )
        let a = AppleFoundationMissionPlanner.mission(from: withMsg, goal: "what's the weather", tier: .onDevice)
        #expect(a.task == nil)
        #expect(a.decline == "I shop for things — try a goal.")

        // A blank decline backfills the deterministic message.
        let blank = MissionDraft(isShoppable: false, title: "", subtitle: "", note: "", parts: [], decline: "  ")
        let b = AppleFoundationMissionPlanner.mission(from: blank, goal: "asdf", tier: .onDevice)
        #expect(b.task == nil)
        #expect(b.decline == RuleBasedMissionPlanner.declineMessage)
    }

    // MARK: Goal cap (the fixed-prompt-cost guard that keeps the model call under context)

    @Test("A short goal is passed to the model untouched (just trimmed)")
    func cappedGoalShort() {
        #expect(AppleFoundationMissionPlanner.cappedGoal("  set up my pour-over corner  ")
            == "set up my pour-over corner")
    }

    @Test("An over-long goal is cut at a word boundary within the cap")
    func cappedGoalLong() {
        let long = String(repeating: "lacrosse gear and more ", count: 60)   // ~1380 chars
        let capped = AppleFoundationMissionPlanner.cappedGoal(long)
        #expect(capped.count <= AppleFoundationMissionPlanner.maxGoalChars)
        #expect(!capped.hasSuffix(" "))            // trimmed
        #expect(!capped.hasSuffix("lacros"))       // never split mid-word
    }
}

/// Recents-merge guarantees: dedupe, most-recent-first, cap.
@Suite("RecentMissionsStore")
@MainActor
struct RecentMissionsStoreTests {

    @Test("Adding goals keeps them most-recent-first")
    func mostRecentFirst() {
        let store = InMemoryRecentMissionsStore()
        store.addRecent("hike kit")
        store.addRecent("pour over corner")
        #expect(store.loadRecents() == ["pour over corner", "hike kit"])
    }

    @Test("Re-adding an existing goal moves it to the front (case-insensitive), no duplicate")
    func dedupeMovesToFront() {
        let store = InMemoryRecentMissionsStore(["a", "b", "c"])
        store.addRecent("B")
        #expect(store.loadRecents() == ["B", "a", "c"])
    }

    @Test("The list is capped at the store cap")
    func capped() {
        let store = InMemoryRecentMissionsStore()
        for i in 0..<10 { store.addRecent("goal \(i)") }
        #expect(store.loadRecents().count == InMemoryRecentMissionsStore.cap)
        #expect(store.loadRecents().first == "goal 9")              // newest kept
    }

    @Test("A blank goal is ignored")
    func blankIgnored() {
        let store = InMemoryRecentMissionsStore(["keep"])
        store.addRecent("   ")
        #expect(store.loadRecents() == ["keep"])
    }

    @Test("SwiftData store round-trips recents with dedupe + cap")
    func swiftDataRoundTrips() throws {
        let store = try SwiftDataRecentMissionsStore(inMemory: true)
        store.addRecent("hike kit")
        store.addRecent("pour over")
        store.addRecent("HIKE KIT")                                  // dup → front, no double
        #expect(store.loadRecents() == ["HIKE KIT", "pour over"])
    }
}
