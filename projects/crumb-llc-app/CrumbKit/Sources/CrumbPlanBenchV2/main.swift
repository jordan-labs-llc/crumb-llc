import CrumbKit
import Foundation
import FoundationModels

/// Second pass: is the on-device model's weak *coverage* a model ceiling, or is it recoverable?
///
/// Runs three variants over the same kit goals and scores them identically to `crumb-plan-bench`:
///
/// * **A — shipping prompt** (control; the guide in `PlannerInstructions`).
/// * **B — anchored prompt**: name the primary thing first, and forbid category words as parts.
/// * **C — union of 3 × B**: sample three plans concurrently and merge them, on the theory that
///   the model's *variance* is uncorrelated with its blind spots, so three cheap samples cover
///   more than one careful one. Latency stays one round trip because the samples run in parallel.

// MARK: - Suite (kit goals only — the ones a planner exists for)

struct Role { let name: String; let cues: [String] }
struct Case { let goal: String; let roles: [Role] }

let suite: [Case] = [
    Case(goal: "set up a home coffee bar", roles: [
        Role(name: "brewer", cues: ["brewer", "coffee maker", "coffeemaker", "espresso", "pour over",
                                    "pour-over", "french press", "dripper", "chemex", "aeropress",
                                    "moka", "drip coffee", "percolator", "coffee pot"]),
        Role(name: "grinder", cues: ["grinder", "burr"]),
        Role(name: "kettle", cues: ["kettle"]),
        Role(name: "coffee", cues: ["bean", "coffee beans", "ground coffee", "roast", "coffee bag"]),
        Role(name: "vessel", cues: ["mug", "cup", "carafe", "server", "glassware"]),
        Role(name: "accessory", cues: ["filter", "scale", "tamper", "frother", "canister", "storage",
                                       "tray", "station"]),
    ]),
    Case(goal: "pack me for a rainy weekend hike", roles: [
        Role(name: "shell", cues: ["rain jacket", "shell", "waterproof jacket", "raincoat", "poncho",
                                   "rain gear", "outerwear"]),
        Role(name: "footwear", cues: ["boot", "shoe", "footwear", "trail runner"]),
        Role(name: "pack", cues: ["backpack", "daypack", "pack", "rucksack"]),
        Role(name: "layers", cues: ["base layer", "fleece", "mid layer", "midlayer", "thermal", "sock"]),
        Role(name: "trousers", cues: ["pant", "trouser", "rain pant"]),
        Role(name: "extras", cues: ["hat", "cap", "glove", "headlamp", "bottle", "hydration", "cover",
                                    "dry bag", "trekking pole", "map"]),
    ]),
    Case(goal: "outfit a home office for video calls", roles: [
        Role(name: "camera", cues: ["webcam", "camera"]),
        Role(name: "audio", cues: ["microphone", "mic", "headset", "headphone", "earbud", "speaker"]),
        Role(name: "lighting", cues: ["light", "lamp", "ring light", "key light"]),
        Role(name: "seating/desk", cues: ["chair", "desk", "standing desk"]),
        Role(name: "display", cues: ["monitor", "display", "screen"]),
        Role(name: "extras", cues: ["stand", "arm", "mount", "backdrop", "hub", "dock", "riser"]),
    ]),
    Case(goal: "premium lacrosse gear", roles: [
        Role(name: "stick", cues: ["stick", "shaft", "head", "crosse"]),
        Role(name: "helmet", cues: ["helmet"]),
        Role(name: "gloves", cues: ["glove"]),
        Role(name: "pads", cues: ["pad", "shoulder", "arm guard", "elbow", "rib"]),
        Role(name: "mouthguard", cues: ["mouthguard", "mouth guard", "mouthpiece"]),
        Role(name: "bag/cleats", cues: ["bag", "cleat", "shoe", "ball"]),
    ]),
    Case(goal: "everything for taco night for eight people", roles: [
        Role(name: "tortilla", cues: ["tortilla", "shell"]),
        Role(name: "protein", cues: ["beef", "chicken", "pork", "carnitas", "protein", "meat", "bean"]),
        Role(name: "salsa/sauce", cues: ["salsa", "sauce", "hot sauce", "guacamole", "crema"]),
        Role(name: "toppings", cues: ["cheese", "topping", "onion", "cilantro", "lime", "jalape"]),
        Role(name: "serveware", cues: ["plate", "bowl", "platter", "napkin", "serving", "tray",
                                       "warmer", "holder"]),
        Role(name: "drinks", cues: ["drink", "margarita", "beer", "soda", "beverage", "agua"]),
    ]),
    Case(goal: "new baby nursery essentials", roles: [
        Role(name: "crib", cues: ["crib", "bassinet", "cot", "mattress"]),
        Role(name: "bedding", cues: ["sheet", "bedding", "swaddle", "blanket", "sleep sack"]),
        Role(name: "changing", cues: ["changing", "diaper", "wipe", "pad"]),
        Role(name: "seating", cues: ["glider", "rocker", "chair"]),
        Role(name: "storage", cues: ["dresser", "storage", "basket", "organizer", "shelf"]),
        Role(name: "monitor/extras", cues: ["monitor", "light", "humidifier", "sound", "mobile"]),
    ]),
    Case(goal: "get me ready for my first marathon", roles: [
        Role(name: "shoes", cues: ["shoe", "trainer", "footwear", "sneaker"]),
        Role(name: "apparel", cues: ["short", "shirt", "singlet", "tight", "sock", "top"]),
        Role(name: "nutrition", cues: ["gel", "nutrition", "electrolyte", "energy", "chew", "drink mix"]),
        Role(name: "hydration", cues: ["bottle", "hydration", "flask", "belt", "vest"]),
        Role(name: "tracking", cues: ["watch", "gps", "tracker", "monitor"]),
        Role(name: "recovery", cues: ["roller", "recovery", "massage", "compression", "balm", "tape"]),
    ]),
]

// MARK: - The two prompts

/// The shipping guide, transcribed so the control runs through the same code path as the variant.
let shippingGuide = """
    You are Crumb, a personal shopping curator. You turn a person's shopping goal into a concrete \
    plan you can shop for.

    Break the goal into the parts to shop for, each with a short human label (what it is) and a \
    concise catalog search query (a few plain keywords, no punctuation) you'd type into a shop's \
    search. Match the plan to the goal's altitude: when the goal names ONE specific item, return \
    exactly one part and set isSingleItem to true. Only when the goal is to outfit a space or an \
    activity that genuinely needs several complementary things, break it into up to 6 parts and \
    set isSingleItem to false.

    If the goal is NOT something a shop can fulfill, set isShoppable to false.
    """

/// The intervention. Two changes, both aimed at the failures the control actually made:
/// it forgot the anchor item, and it emitted taxonomy ("Layer", "Sun") instead of products.
let anchoredGuide = """
    You are Crumb, a personal shopping curator. You turn a person's shopping goal into a concrete \
    plan you can shop for.

    Break the goal into the parts to shop for, each with a short human label and a concise catalog \
    search query (a few plain keywords, no punctuation).

    Two hard rules:

    1. THE ANCHOR COMES FIRST. Part 1 must be the single main object the goal is really about — \
    the thing that would make the whole plan pointless if it were missing. For "set up a home \
    coffee bar" that is the coffee maker, not the mug. For "pack me for a rainy hike" that is the \
    waterproof jacket, not the water bottle. Name it explicitly before you list anything that \
    supports it.

    2. EVERY PART IS A PRODUCT, NEVER A CATEGORY. "Rain jacket" is a product; "Outerwear", \
    "Layer", "Sun protection", "Footwear" and "Hydration" are categories and are forbidden — no \
    shop search returns a useful result for them. If you catch yourself writing a category, \
    replace it with the specific item a person would actually buy: "hiking boots", "merino base \
    layer", "sun hat", "water bottle".

    Then add the remaining pieces someone would be missing after buying the anchor, up to 6 parts \
    total. Set isSingleItem to false for any goal that needs more than one thing.

    If the goal is NOT something a shop can fulfill, set isShoppable to false.
    """

// MARK: - Runner

func covered(_ roles: [Role], _ parts: [(String, String)]) -> Set<String> {
    let hay = parts.map { "\($0.0) \($0.1)".lowercased() }
    return Set(roles.filter { r in hay.contains { t in r.cues.contains { t.contains($0) } } }.map(\.name))
}

/// The category words the intervention forbids — scored so we can tell whether the rule landed.
let categoryWords: Set<String> = [
    "footwear", "outerwear", "layer", "layers", "sun", "sun protection", "hydration", "apparel",
    "clothing", "accessories", "accessory", "gear", "equipment", "protein", "toppings", "extras",
    "storage", "bedding", "seating", "nutrition", "audio", "lighting", "electronics", "supplies",
    "essentials", "pack", "bag", "tools", "furniture",
]

func categoryCount(_ parts: [(String, String)]) -> Int {
    parts.filter { categoryWords.contains($0.0.lowercased().trimmingCharacters(in: .whitespaces)) }.count
}

func draft(goal: String, guide: String) async -> [(String, String)] {
    let session = LanguageModelSession(instructions: Instructions(guide))
    let prompt = """
        The user's goal:
        "\(goal)"

        Plan this mission: a short title, a short subtitle of context, a one-sentence curator note \
        framing the plan, and the parts (label + search query) to shop for.
        """
    do {
        let r = try await session.respond(to: prompt, generating: MissionDraft.self)
        return r.content.parts
            .map { ($0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                    $0.query.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty || !$0.1.isEmpty }
    } catch {
        FileHandle.standardError.write("    ! \(error.localizedDescription)\n".data(using: .utf8)!)
        return []
    }
}

/// Variant C: three concurrent samples, merged by de-duplicating on the cleaned query.
func unionDraft(goal: String, guide: String) async -> [(String, String)] {
    async let a = draft(goal: goal, guide: guide)
    async let b = draft(goal: goal, guide: guide)
    async let c = draft(goal: goal, guide: guide)
    let all = await a + b + c
    var seen = Set<String>(); var out: [(String, String)] = []
    for p in all {
        let key = p.1.isEmpty ? p.0.lowercased() : p.1.lowercased()
        guard seen.insert(key).inserted else { continue }
        out.append(p)
        if out.count == 6 { break }
    }
    return out
}

let trials = Int(ProcessInfo.processInfo.environment["TRIALS"] ?? "3") ?? 3
var scores: [String: [Double]] = ["A": [], "B": [], "C": []]
var cats: [String: [Int]] = ["A": [], "B": [], "C": []]
var times: [String: [Double]] = ["A": [], "B": [], "C": []]

for c in suite {
    FileHandle.standardError.write("\n\(c.goal)\n".data(using: .utf8)!)
    for t in 1...trials {
        for (name, run) in [
            ("A", { await draft(goal: c.goal, guide: shippingGuide) }),
            ("B", { await draft(goal: c.goal, guide: anchoredGuide) }),
            ("C", { await unionDraft(goal: c.goal, guide: anchoredGuide) }),
        ] as [(String, () async -> [(String, String)])] {
            let t0 = Date()
            let parts = await run()
            let dt = Date().timeIntervalSince(t0)
            let cov = Double(covered(c.roles, parts).count) / Double(c.roles.count)
            let cat = categoryCount(parts)
            scores[name]!.append(cov); cats[name]!.append(cat); times[name]!.append(dt)
            FileHandle.standardError.write(
                "  \(name) t\(t)  \(String(format: "%4.1fs", dt))  cov \(String(format: "%3.0f%%", cov * 100))  cat \(cat)  \(parts.map(\.0).joined(separator: " | "))\n"
                    .data(using: .utf8)!)
        }
    }
}

func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

var out = ["", "================ VARIANT COMPARISON ================",
           "variant                       coverage   category-parts   latency"]
for (name, label) in [("A", "A  shipping prompt"), ("B", "B  anchored prompt"),
                      ("C", "C  union of 3 x B")] {
    out.append(String(format: "%-28s  %5.0f%%   %12.2f   %6.1fs",
                      (label as NSString).utf8String!,
                      mean(scores[name]!) * 100,
                      mean(cats[name]!.map(Double.init)),
                      mean(times[name]!)))
}
FileHandle.standardError.write((out.joined(separator: "\n") + "\n").data(using: .utf8)!)
