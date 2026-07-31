import CrumbKit
import Foundation

/// Evaluates the REAL ``AppleFoundationMissionPlanner`` against the live on-device model.
///
/// The question it answers: is Apple's on-device Foundation Model good enough to be the thing that
/// decomposes a shopping goal into a multi-part, searchable plan? It runs the shipping planner (not
/// a hand-rolled prompt) over a labelled goal suite, N trials each, and scores four things that
/// decide whether a planner is usable in a product:
///
/// 1. **Altitude** — does it correctly call "one item" vs "a kit of several things"?
/// 2. **Role coverage** — for kit goals, does it name the parts a person would actually need?
/// 3. **Stability** — does it give the *same* answer twice? A planner that reshuffles per run
///    cannot be the spine of a UI that shows a checklist.
/// 4. **Query hygiene** — are the per-part queries plain searchable keywords, or restated prose?
///
/// Output is JSON on stdout (`--json`) plus a human summary on stderr.

// MARK: - Suite

enum Altitude: String { case single, kit }

struct Role {
    let name: String
    /// Any of these substrings (lowercased) in a part's label or query counts as covering the role.
    let cues: [String]
}

struct Case {
    let goal: String
    let altitude: Altitude
    let roles: [Role]
    var shoppable: Bool = true
}

let suite: [Case] = [
    // ---- kit goals: the whole reason to have a planner at all ----
    Case(goal: "set up a home coffee bar", altitude: .kit, roles: [
        Role(name: "brewer", cues: ["brewer", "coffee maker", "coffeemaker", "espresso", "pour over",
                                    "pour-over", "french press", "dripper", "chemex", "aeropress",
                                    "moka", "drip coffee", "percolator"]),
        Role(name: "grinder", cues: ["grinder", "burr"]),
        Role(name: "kettle", cues: ["kettle"]),
        Role(name: "coffee", cues: ["bean", "coffee beans", "ground coffee", "roast", "coffee bag"]),
        Role(name: "vessel", cues: ["mug", "cup", "carafe", "server", "glassware"]),
        Role(name: "accessory", cues: ["filter", "scale", "tamper", "frother", "canister", "storage",
                                       "tray", "station"]),
    ]),
    Case(goal: "pack me for a rainy weekend hike", altitude: .kit, roles: [
        Role(name: "shell", cues: ["rain jacket", "shell", "waterproof jacket", "raincoat", "poncho"]),
        Role(name: "footwear", cues: ["boot", "shoe", "footwear", "trail runner"]),
        Role(name: "pack", cues: ["backpack", "daypack", "pack", "rucksack"]),
        Role(name: "layers", cues: ["base layer", "fleece", "mid layer", "midlayer", "thermal", "sock"]),
        Role(name: "trousers", cues: ["pant", "trouser", "rain pant"]),
        Role(name: "extras", cues: ["hat", "cap", "glove", "headlamp", "bottle", "hydration", "cover",
                                    "dry bag", "trekking pole", "map"]),
    ]),
    Case(goal: "outfit a home office for video calls", altitude: .kit, roles: [
        Role(name: "camera", cues: ["webcam", "camera"]),
        Role(name: "audio", cues: ["microphone", "mic", "headset", "headphone", "earbud", "speaker"]),
        Role(name: "lighting", cues: ["light", "lamp", "ring light", "key light"]),
        Role(name: "seating/desk", cues: ["chair", "desk", "standing desk"]),
        Role(name: "display", cues: ["monitor", "display", "screen"]),
        Role(name: "extras", cues: ["stand", "arm", "mount", "backdrop", "hub", "dock", "riser"]),
    ]),
    Case(goal: "premium lacrosse gear", altitude: .kit, roles: [
        Role(name: "stick", cues: ["stick", "shaft", "head", "crosse"]),
        Role(name: "helmet", cues: ["helmet"]),
        Role(name: "gloves", cues: ["glove"]),
        Role(name: "pads", cues: ["pad", "shoulder", "arm guard", "elbow", "rib"]),
        Role(name: "mouthguard", cues: ["mouthguard", "mouth guard", "mouthpiece"]),
        Role(name: "bag/cleats", cues: ["bag", "cleat", "shoe", "ball"]),
    ]),
    Case(goal: "everything for taco night for eight people", altitude: .kit, roles: [
        Role(name: "tortilla", cues: ["tortilla", "shell"]),
        Role(name: "protein", cues: ["beef", "chicken", "pork", "carnitas", "protein", "meat", "bean"]),
        Role(name: "salsa/sauce", cues: ["salsa", "sauce", "hot sauce", "guacamole", "crema"]),
        Role(name: "toppings", cues: ["cheese", "topping", "onion", "cilantro", "lime", "jalape"]),
        Role(name: "serveware", cues: ["plate", "bowl", "platter", "napkin", "serving", "tray",
                                       "warmer", "holder"]),
        Role(name: "drinks", cues: ["drink", "margarita", "beer", "soda", "beverage", "agua"]),
    ]),
    Case(goal: "new baby nursery essentials", altitude: .kit, roles: [
        Role(name: "crib", cues: ["crib", "bassinet", "cot", "mattress"]),
        Role(name: "bedding", cues: ["sheet", "bedding", "swaddle", "blanket", "sleep sack"]),
        Role(name: "changing", cues: ["changing", "diaper", "wipe", "pad"]),
        Role(name: "seating", cues: ["glider", "rocker", "chair"]),
        Role(name: "storage", cues: ["dresser", "storage", "basket", "organizer", "shelf"]),
        Role(name: "monitor/extras", cues: ["monitor", "light", "humidifier", "sound", "mobile"]),
    ]),

    // ---- single-item goals: over-decomposing these is the opposite failure ----
    Case(goal: "premium jasmine tea", altitude: .single, roles: []),
    Case(goal: "a cast iron skillet", altitude: .single, roles: []),
    Case(goal: "a warm winter coat for a rainy commute", altitude: .single, roles: []),
    Case(goal: "a pour-over kettle with a gooseneck spout", altitude: .single, roles: []),

    // ---- genuinely ambiguous: no altitude is "wrong", we only measure stability ----
    Case(goal: "get me ready for my first marathon", altitude: .kit, roles: [
        Role(name: "shoes", cues: ["shoe", "trainer", "footwear", "sneaker"]),
        Role(name: "apparel", cues: ["short", "shirt", "singlet", "tight", "sock", "top"]),
        Role(name: "nutrition", cues: ["gel", "nutrition", "electrolyte", "energy", "chew", "drink mix"]),
        Role(name: "hydration", cues: ["bottle", "hydration", "flask", "belt", "vest"]),
        Role(name: "tracking", cues: ["watch", "gps", "tracker", "monitor"]),
        Role(name: "recovery", cues: ["roller", "recovery", "massage", "compression", "balm", "tape"]),
    ]),

    // ---- must decline ----
    Case(goal: "what is the weather?", altitude: .single, roles: [], shoppable: false),
]

// MARK: - Scoring (pure)

struct Trial: Codable {
    let goal: String
    let trial: Int
    let tier: String
    let shoppable: Bool
    let isSingleItem: Bool
    let parts: [String]
    let queries: [String]
    let seconds: Double
    let coveredRoles: [String]
    let cleanQueries: Int
    let echoQueries: Int
}

func covered(roles: [Role], parts: [String], queries: [String]) -> [String] {
    let hay = zip(parts, queries).map { "\($0) \($1)".lowercased() }
    return roles.filter { role in
        hay.contains { text in role.cues.contains { text.contains($0) } }
    }.map(\.name)
}

/// A query is "clean" when it looks like something you'd type into a shop's search box:
/// no punctuation, at most six words, not empty.
func isCleanQuery(_ q: String) -> Bool {
    let words = q.split(separator: " ")
    guard (1...6).contains(words.count) else { return false }
    return !q.contains(where: { ",.;:!?\"'()/".contains($0) })
}

/// A query that just restates the whole goal — the failure mode the shipping planner has today.
func isEcho(_ q: String, goal: String) -> Bool {
    func norm(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(["a", "an", "the", "for", "me", "my", "of", "to", "with", "and"])
    }
    let g = norm(goal), t = norm(q)
    guard !g.isEmpty, !t.isEmpty else { return false }
    return g.isSubset(of: t) || t == g
}

func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
    if a.isEmpty && b.isEmpty { return 1 }
    return Double(a.intersection(b).count) / Double(a.union(b).count)
}

// MARK: - Run

let trialCount = Int(ProcessInfo.processInfo.environment["TRIALS"] ?? "5") ?? 5

/// Which seam to score. `foundation` is the pure-model planner (the original baseline);
/// `direct` is the shipping composition — triage for altitude, `KitRecipes` for coverage on
/// recognized intents, the model for the tail.
let plannerName = ProcessInfo.processInfo.environment["PLANNER"] ?? "direct"
let planner: any MissionPlanner = plannerName == "foundation"
    ? AppleFoundationMissionPlanner()
    : DirectMissionPlanner(triage: AppleFoundationGoalTriage())
let taste = SeedData.defaultTasteProfile
var results: [Trial] = []

FileHandle.standardError.write("Running \(suite.count) goals x \(trialCount) trials — planner=\(plannerName)\n".data(using: .utf8)!)

for c in suite {
    for t in 1...trialCount {
        let start = Date()
        let planned = await planner.plan(goal: c.goal, profile: taste)
        let elapsed = Date().timeIntervalSince(start)
        let parts = planned.task?.plan ?? []
        let queries = planned.task?.searchQueries ?? []
        let tier: String
        switch planned.tier {
        case .privateCloud: tier = "privateCloud"
        case .onDevice: tier = "onDevice"
        case .ruleBased(let r): tier = "ruleBased(\(r.map(String.init(describing:)) ?? "chosen"))"
        }
        let trial = Trial(
            goal: c.goal, trial: t, tier: tier,
            shoppable: planned.isShoppable,
            isSingleItem: planned.task?.isSingleItem ?? false,
            parts: parts, queries: queries, seconds: elapsed,
            coveredRoles: covered(roles: c.roles, parts: parts, queries: queries),
            cleanQueries: queries.filter(isCleanQuery).count,
            echoQueries: queries.filter { isEcho($0, goal: c.goal) }.count
        )
        results.append(trial)
        FileHandle.standardError.write(
            "  \(String(format: "%5.1fs", elapsed))  \(c.goal.prefix(38).padding(toLength: 38, withPad: " ", startingAt: 0))  t\(t)  \(tier)  single=\(trial.isSingleItem)  parts=\(parts.count)  \(parts.joined(separator: " | "))\n"
                .data(using: .utf8)!
        )
    }
}

// MARK: - Report

func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

var lines: [String] = ["", "==================== SUMMARY ===================="]
var altitudeHits = 0, altitudeTotal = 0
var coverageSum = 0.0, coverageN = 0
var stabilitySum = 0.0, stabilityN = 0

for c in suite {
    let rows = results.filter { $0.goal == c.goal }
    guard !rows.isEmpty else { continue }

    if c.shoppable {
        let hits = rows.filter { $0.isSingleItem == (c.altitude == .single) }.count
        altitudeHits += hits; altitudeTotal += rows.count
    } else {
        let hits = rows.filter { !$0.shoppable }.count
        altitudeHits += hits; altitudeTotal += rows.count
    }

    let partCounts = rows.map(\.parts.count)
    let coverages = rows.map { r -> Double in
        c.roles.isEmpty ? Double.nan : Double(r.coveredRoles.count) / Double(c.roles.count)
    }.filter { !$0.isNaN }
    if !coverages.isEmpty {
        coverageSum += coverages.reduce(0, +) / Double(coverages.count); coverageN += 1
    }

    // Stability: mean pairwise Jaccard over the *set of part labels* (lowercased), across trials.
    let sets = rows.map { Set($0.parts.map { $0.lowercased() }) }
    var pairs: [Double] = []
    for i in sets.indices { for j in sets.indices where j > i { pairs.append(jaccard(sets[i], sets[j])) } }
    let stability = pairs.isEmpty ? 1 : pairs.reduce(0, +) / Double(pairs.count)
    if c.shoppable { stabilitySum += stability; stabilityN += 1 }

    let cov = coverages.isEmpty ? "—" : pct(coverages.reduce(0, +) / Double(coverages.count))
    let alt = rows.map { $0.shoppable ? ($0.isSingleItem ? "1" : "K") : "×" }.joined()
    lines.append(String(format: "%-44s alt[%@]  parts %d–%d  roles %@  stable %@  %.1fs",
                        (c.goal as NSString).utf8String!, alt,
                        partCounts.min() ?? 0, partCounts.max() ?? 0, cov, pct(stability),
                        rows.map(\.seconds).reduce(0, +) / Double(rows.count)))
}

let allSeconds = results.map(\.seconds).sorted()
let degraded = results.filter { $0.tier.hasPrefix("ruleBased") }.count
let allQueries = results.flatMap(\.queries).count
let cleanQ = results.map(\.cleanQueries).reduce(0, +)
let echoQ = results.map(\.echoQueries).reduce(0, +)

lines.append("")
lines.append("Altitude correct (single vs kit vs decline): \(pct(Double(altitudeHits) / Double(max(1, altitudeTotal)))) (\(altitudeHits)/\(altitudeTotal))")
lines.append("Mean role coverage on kit goals:            \(pct(coverageSum / Double(max(1, coverageN))))")
lines.append("Mean part-set stability across trials:      \(pct(stabilitySum / Double(max(1, stabilityN))))")
lines.append("Clean queries:                              \(pct(Double(cleanQ) / Double(max(1, allQueries)))) (\(cleanQ)/\(allQueries))")
lines.append("Queries that echo the whole goal:           \(pct(Double(echoQ) / Double(max(1, allQueries)))) (\(echoQ)/\(allQueries))")
lines.append("Degraded to rule-based floor:               \(degraded)/\(results.count)")
lines.append(String(format: "Latency p50 / p90 / max:                    %.1fs / %.1fs / %.1fs",
                    allSeconds[allSeconds.count / 2],
                    allSeconds[Int(Double(allSeconds.count) * 0.9)],
                    allSeconds.last ?? 0))

FileHandle.standardError.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)

if CommandLine.arguments.contains("--json") {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try enc.encode(results), encoding: .utf8)!)
}
