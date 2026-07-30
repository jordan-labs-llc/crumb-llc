import Foundation

/// The deterministic answer to "what goes in this kit".
///
/// ## Why this exists rather than a better prompt
///
/// A benchmark of ~170 live generations through the on-device model settled the question. It is
/// genuinely good at *judgment* — 93% correct on whether a goal is one item or a kit, 100% on
/// declining non-shopping goals, 97% clean searchable queries, 2.7s median. It is not good at
/// *knowledge*: it named only 44% of the parts a kit actually needs, and two runs of the same goal
/// agreed 27% of the time. Asked for a home coffee bar it returned "Kettle | Filter | Cup" — three
/// accessories to a machine it never mentioned. Asked to outfit a home office *for video calls* it
/// produced no camera, microphone or headset in five consecutive attempts.
///
/// Both plausible fixes were measured and neither closes it. An anchored prompt ("name the main
/// object first; never emit a category word") drove unsearchable parts like "Outerwear" and
/// "Hydration" to exactly zero — and coverage went *down*, because the tightened model returned
/// fewer parts. Unioning three concurrent samples reached 61%, and the curve is flat by five. You
/// cannot instruct a model into knowing what a nursery needs.
///
/// The one goal the model handled well is the tell: "premium lacrosse gear" produced
/// `lacrosse stick | lacrosse helmet | lacrosse shoulder pads | lacrosse bag`, character-identical
/// across three runs. The goal handed it the domain noun and it prefixed that noun onto slot words.
/// Where the goal supplies no such noun it fills the slots from the taste profile instead, which is
/// where `merino wool ergonomic chair` and `solid wood desk` came from — 47% of kit queries carried
/// a taste adjective welded onto the product noun.
///
/// So: the model keeps the judgments it wins, and coverage becomes a table. This is
/// ``RuleBasedMissionPlanner/kitExpansion(for:)`` generalized from its single "lacrosse" row — that
/// design was right, it was just one row deep.
///
/// ## What a recipe owes the person
///
/// Every recipe carries an `assumption` that is **stated, not hidden**, because a table cannot know
/// whether this is a goalie or a field player, a filter coffee household or an espresso one. The
/// assumption surfaces in the thread as an editable notice; the plan it produces is a starting
/// point the person corrects, which is the whole reason the plan is visible at all.
public enum KitRecipes {

    /// One recognized intent and the parts it decomposes into.
    public struct Recipe: Sendable {
        /// Stable identifier, used by tests and by the trace.
        public let id: String
        /// Phrases that name this domain. Matched as substrings of the cleaned, lowercased goal.
        public let cues: [String]
        /// The default this recipe is guessing at, said out loud so it can be corrected.
        public let assumption: String
        /// The parts, anchor first. Ordering matters: the first part is the thing whose absence
        /// would make the rest pointless, and it is what the person sees Crumb shop for first.
        public let parts: [(label: String, query: String)]
    }

    /// The recipe for `goal`, or `nil` when nothing recognizes it — in which case the caller falls
    /// through to the model, which is exactly where the long tail should be handled.
    ///
    /// Longest cue wins, so "home office" beats "office" and "pour over" beats "coffee". Pure.
    public static func recipe(for goal: String) -> Recipe? {
        let lowered = RuleBasedMissionPlanner.clean(query: goal).lowercased()
        guard !lowered.isEmpty else { return nil }
        let kitIntent = RuleBasedMissionPlanner.mentionsKitIntent(lowered)

        // The gate is uniform rather than per-recipe. Every domain noun in this table also appears
        // inside a perfectly ordinary single product — "running shoes", "nursery lamp", "home office
        // chair", "espresso machine" — so a recipe may only fire when the person actually asked for
        // a *set* of things. A per-recipe opt-out was tried first and immediately expanded "running
        // shoes" into a six-part marathon kit. Under-firing is the cheap direction: an unrecognized
        // kit falls through to the model, which is what the model is for.
        guard kitIntent else { return nil }

        var best: (recipe: Recipe, cueLength: Int)?
        for recipe in all {
            for cue in recipe.cues where lowered.contains(cue) {
                if best == nil || cue.count > best!.cueLength {
                    best = (recipe, cue.count)
                }
            }
        }
        return best?.recipe
    }

    /// Every recipe. Each is capped at ``RuleBasedMissionPlanner/maxParts``, leads with its anchor,
    /// and uses plain searchable queries — the thing a person would type into a shop, never a
    /// category word, because a catalog search for "Hydration" returns nothing useful.
    public static let all: [Recipe] = [

        // MARK: Kitchen & drink

        Recipe(
            id: "coffee-bar",
            cues: ["coffee bar", "coffee station", "coffee corner", "coffee setup", "coffee nook"],
            assumption: "Assuming filter coffee for one or two people. Say the word if you want "
                + "espresso and I'll rework it around a machine.",
            parts: [
                (label: "Coffee maker", query: "pour over coffee maker"),
                (label: "Grinder", query: "burr coffee grinder"),
                (label: "Kettle", query: "gooseneck kettle"),
                (label: "Coffee beans", query: "whole bean coffee"),
                (label: "Filters", query: "coffee filters"),
                (label: "Mugs", query: "ceramic coffee mug"),
            ]
        ),
        Recipe(
            id: "espresso-bar",
            cues: ["espresso bar", "espresso setup", "espresso station", "espresso"],
            assumption: "Assuming a home espresso setup you'll pull shots on daily.",
            parts: [
                (label: "Espresso machine", query: "espresso machine"),
                (label: "Grinder", query: "espresso burr grinder"),
                (label: "Tamper", query: "espresso tamper"),
                (label: "Milk frothing pitcher", query: "milk frothing pitcher"),
                (label: "Espresso beans", query: "espresso beans"),
                (label: "Espresso cups", query: "espresso cups"),
            ]
        ),
        Recipe(
            id: "tea-bar",
            cues: ["tea bar", "tea station", "tea corner", "tea setup", "loose leaf tea"],
            assumption: "Assuming loose-leaf tea. Tell me if you'd rather have bags.",
            parts: [
                (label: "Teapot", query: "glass teapot infuser"),
                (label: "Kettle", query: "electric kettle temperature control"),
                (label: "Loose leaf tea", query: "loose leaf tea"),
                (label: "Tea infuser", query: "tea infuser"),
                (label: "Cups", query: "tea cups"),
                (label: "Storage tins", query: "tea storage tin"),
            ]
        ),
        Recipe(
            id: "bar-cart",
            cues: ["bar cart", "home bar", "cocktail bar", "cocktail"],
            assumption: "Assuming a starter cocktail setup rather than a stocked spirits shelf.",
            parts: [
                (label: "Bar cart", query: "rolling bar cart"),
                (label: "Cocktail shaker set", query: "cocktail shaker set"),
                (label: "Mixing glass", query: "cocktail mixing glass"),
                (label: "Glassware", query: "rocks glasses set"),
                (label: "Bitters", query: "cocktail bitters"),
                (label: "Ice mold", query: "large ice cube mold"),
            ]
        ),
        Recipe(
            id: "taco-night",
            cues: ["taco night", "taco bar", "tacos", "taco"],
            assumption: "Assuming you're cooking rather than ordering in. Tell me the headcount "
                + "and I'll size it.",
            parts: [
                (label: "Tortillas", query: "corn tortillas"),
                (label: "Salsa", query: "salsa"),
                (label: "Hot sauce", query: "hot sauce"),
                (label: "Serving bowls", query: "serving bowls set"),
                (label: "Tortilla warmer", query: "tortilla warmer"),
                (label: "Margarita mix", query: "margarita mix"),
            ]
        ),
        Recipe(
            id: "baking",
            cues: ["baking", "bake", "pastry"],
            assumption: "Assuming home baking from scratch — cakes and bread rather than pastry work.",
            parts: [
                (label: "Stand mixer", query: "stand mixer"),
                (label: "Mixing bowls", query: "mixing bowls set"),
                (label: "Kitchen scale", query: "digital kitchen scale"),
                (label: "Baking pans", query: "baking pan set"),
                (label: "Measuring cups", query: "measuring cups spoons"),
                (label: "Cooling rack", query: "wire cooling rack"),
            ]
        ),
        Recipe(
            id: "grilling",
            cues: ["grilling", "barbecue", "bbq", "grill"],
            assumption: "Assuming a charcoal grill. Say if you're on gas and I'll swap the fuel parts.",
            parts: [
                (label: "Grill", query: "charcoal grill"),
                (label: "Charcoal", query: "lump charcoal"),
                (label: "Chimney starter", query: "charcoal chimney starter"),
                (label: "Tongs and spatula", query: "grill tools set"),
                (label: "Meat thermometer", query: "instant read meat thermometer"),
                (label: "Grill brush", query: "grill cleaning brush"),
            ]
        ),
        Recipe(
            id: "kitchen-starter",
            cues: ["first apartment", "kitchen essentials", "kitchen starter", "stock my kitchen", "kitchen"],
            assumption: "Assuming a first kitchen with nothing in it yet.",
            parts: [
                (label: "Chef's knife", query: "chef knife"),
                (label: "Cutting board", query: "wood cutting board"),
                (label: "Skillet", query: "cast iron skillet"),
                (label: "Saucepan", query: "stainless saucepan"),
                (label: "Mixing bowls", query: "mixing bowls set"),
                (label: "Utensil set", query: "kitchen utensil set"),
            ]
        ),

        // MARK: Home & work

        Recipe(
            id: "video-call-office",
            cues: ["video call", "video calls", "video conferencing", "zoom call", "work from home",
                   "home office", "remote work"],
            assumption: "Assuming you're upgrading how you look and sound on calls, not furnishing "
                + "the whole room.",
            parts: [
                (label: "Webcam", query: "1080p webcam"),
                (label: "Microphone", query: "usb microphone"),
                (label: "Key light", query: "desk key light"),
                (label: "Headset", query: "wireless headset"),
                (label: "Monitor", query: "27 inch monitor"),
                (label: "Laptop stand", query: "laptop stand"),
            ]
        ),
        Recipe(
            id: "desk-setup",
            cues: ["desk setup", "standing desk setup", "workspace", "desk"],
            assumption: "Assuming a desk you'll work full days at.",
            parts: [
                (label: "Desk", query: "standing desk"),
                (label: "Chair", query: "ergonomic office chair"),
                (label: "Monitor", query: "27 inch monitor"),
                (label: "Keyboard", query: "mechanical keyboard"),
                (label: "Mouse", query: "wireless mouse"),
                (label: "Desk lamp", query: "desk lamp"),
            ]
        ),
        Recipe(
            id: "nursery",
            cues: ["nursery", "new baby", "baby essentials", "baby registry"],
            assumption: "Assuming a newborn and a room starting from empty.",
            parts: [
                (label: "Crib", query: "convertible crib"),
                (label: "Crib mattress", query: "crib mattress"),
                (label: "Changing table", query: "changing table"),
                (label: "Glider chair", query: "nursery glider chair"),
                (label: "Dresser", query: "nursery dresser"),
                (label: "Baby monitor", query: "video baby monitor"),
            ]
        ),
        Recipe(
            id: "home-gym",
            cues: ["home gym", "garage gym", "workout space", "strength training"],
            assumption: "Assuming a small space and free weights rather than machines.",
            parts: [
                (label: "Adjustable dumbbells", query: "adjustable dumbbells"),
                (label: "Bench", query: "adjustable weight bench"),
                (label: "Kettlebell", query: "kettlebell"),
                (label: "Resistance bands", query: "resistance bands set"),
                (label: "Exercise mat", query: "exercise mat"),
                (label: "Pull-up bar", query: "doorway pull up bar"),
            ]
        ),
        Recipe(
            id: "cleaning",
            cues: ["cleaning supplies", "cleaning kit", "clean my"],
            assumption: "Assuming a general household restock.",
            parts: [
                (label: "All-purpose cleaner", query: "all purpose cleaner"),
                (label: "Microfiber cloths", query: "microfiber cleaning cloths"),
                (label: "Vacuum", query: "cordless stick vacuum"),
                (label: "Mop", query: "spray mop"),
                (label: "Dish soap", query: "dish soap"),
                (label: "Trash bags", query: "trash bags"),
            ]
        ),

        // MARK: Outdoors & travel

        Recipe(
            id: "rain-hike",
            cues: ["rainy hike", "rainy weekend hike", "wet weather hike", "hike", "hiking"],
            assumption: "Assuming a day hike in cool, wet weather rather than an overnight.",
            parts: [
                (label: "Rain jacket", query: "waterproof rain jacket"),
                (label: "Hiking boots", query: "waterproof hiking boots"),
                (label: "Daypack", query: "hiking daypack"),
                (label: "Base layer", query: "merino base layer"),
                (label: "Hiking socks", query: "wool hiking socks"),
                (label: "Rain pants", query: "waterproof hiking pants"),
            ]
        ),
        Recipe(
            id: "camping",
            cues: ["camping", "campsite", "car camping"],
            assumption: "Assuming car camping in three-season weather.",
            parts: [
                (label: "Tent", query: "camping tent"),
                (label: "Sleeping bag", query: "sleeping bag"),
                (label: "Sleeping pad", query: "sleeping pad"),
                (label: "Camp stove", query: "camping stove"),
                (label: "Headlamp", query: "headlamp"),
                (label: "Cooler", query: "camping cooler"),
            ]
        ),
        Recipe(
            id: "ski",
            cues: ["ski", "skiing", "snowboard", "snowboarding"],
            assumption: "Assuming resort riding and that you'll rent skis or a board to start.",
            parts: [
                (label: "Helmet", query: "ski helmet"),
                (label: "Goggles", query: "ski goggles"),
                (label: "Jacket", query: "ski jacket"),
                (label: "Snow pants", query: "ski pants"),
                (label: "Gloves", query: "ski gloves"),
                (label: "Base layers", query: "thermal base layer set"),
            ]
        ),
        Recipe(
            id: "beach",
            cues: ["beach day", "beach trip", "beach"],
            assumption: "Assuming a day trip rather than a week away.",
            parts: [
                (label: "Beach towel", query: "beach towel"),
                (label: "Beach umbrella", query: "beach umbrella"),
                (label: "Cooler bag", query: "insulated cooler bag"),
                (label: "Sunscreen", query: "sunscreen spf 50"),
                (label: "Beach chair", query: "folding beach chair"),
                (label: "Dry bag", query: "waterproof dry bag"),
            ]
        ),
        Recipe(
            id: "carry-on-travel",
            cues: ["carry on", "carry-on", "travel essentials", "packing for a trip", "weekend trip"],
            assumption: "Assuming a short trip you can do without checking a bag.",
            parts: [
                (label: "Carry-on suitcase", query: "carry on suitcase"),
                (label: "Packing cubes", query: "packing cubes"),
                (label: "Toiletry bag", query: "toiletry bag"),
                (label: "Travel adapter", query: "universal travel adapter"),
                (label: "Neck pillow", query: "travel neck pillow"),
                (label: "Portable charger", query: "portable phone charger"),
            ]
        ),
        Recipe(
            id: "picnic",
            cues: ["picnic"],
            assumption: "Assuming an outdoor picnic for a few people.",
            parts: [
                (label: "Picnic blanket", query: "waterproof picnic blanket"),
                (label: "Picnic basket", query: "picnic basket"),
                (label: "Cooler bag", query: "insulated cooler bag"),
                (label: "Reusable plates", query: "reusable picnic plates"),
                (label: "Wine tumblers", query: "outdoor wine tumblers"),
                (label: "Bottle opener", query: "bottle opener corkscrew"),
            ]
        ),

        // MARK: Sport

        Recipe(
            id: "lacrosse",
            cues: ["lacrosse"],
            assumption: "Assuming a high-school field player. Tell me if this is for a goalie or "
                + "girls' lacrosse and I'll rework the picks.",
            parts: [
                (label: "Lacrosse stick", query: "lacrosse stick complete"),
                (label: "Helmet", query: "lacrosse helmet"),
                (label: "Gloves", query: "lacrosse gloves"),
                (label: "Shoulder pads", query: "lacrosse shoulder pads"),
                (label: "Arm pads", query: "lacrosse arm pads"),
                (label: "Cleats", query: "lacrosse cleats"),
            ]
        ),
        Recipe(
            id: "running",
            cues: ["marathon", "half marathon", "running", "couch to 5k", "5k", "10k"],
            assumption: "Assuming road running and that you're building distance from scratch.",
            parts: [
                (label: "Running shoes", query: "running shoes"),
                (label: "Running socks", query: "running socks"),
                (label: "Shorts", query: "running shorts"),
                (label: "Technical top", query: "running shirt moisture wicking"),
                (label: "Energy gels", query: "running energy gels"),
                (label: "Water bottle", query: "handheld running water bottle"),
            ]
        ),
        Recipe(
            id: "cycling",
            cues: ["cycling", "road bike", "bike commute", "biking"],
            assumption: "Assuming road riding and that you already have the bike.",
            parts: [
                (label: "Helmet", query: "bike helmet"),
                (label: "Lights", query: "bike lights front rear"),
                (label: "Lock", query: "bike lock"),
                (label: "Padded shorts", query: "padded cycling shorts"),
                (label: "Floor pump", query: "bike floor pump"),
                (label: "Repair kit", query: "bike tire repair kit"),
            ]
        ),
        Recipe(
            id: "yoga",
            cues: ["yoga", "pilates"],
            assumption: "Assuming practice at home rather than in a studio.",
            parts: [
                (label: "Yoga mat", query: "yoga mat"),
                (label: "Blocks", query: "yoga blocks"),
                (label: "Strap", query: "yoga strap"),
                (label: "Bolster", query: "yoga bolster"),
                (label: "Mat towel", query: "yoga mat towel"),
                (label: "Mat bag", query: "yoga mat bag"),
            ]
        ),
        Recipe(
            id: "golf",
            cues: ["golf"],
            assumption: "Assuming a beginner who'll play a few times a season.",
            parts: [
                (label: "Golf clubs", query: "golf club set"),
                (label: "Golf bag", query: "golf stand bag"),
                (label: "Golf balls", query: "golf balls"),
                (label: "Glove", query: "golf glove"),
                (label: "Tees", query: "golf tees"),
                (label: "Rangefinder", query: "golf rangefinder"),
            ]
        ),
        Recipe(
            id: "tennis",
            cues: ["tennis", "pickleball"],
            assumption: "Assuming recreational play.",
            parts: [
                (label: "Racquet", query: "tennis racquet"),
                (label: "Balls", query: "tennis balls"),
                (label: "Court shoes", query: "tennis shoes"),
                (label: "Grip tape", query: "tennis overgrip"),
                (label: "Racquet bag", query: "tennis racquet bag"),
                (label: "Wristbands", query: "tennis wristbands"),
            ]
        ),
        Recipe(
            id: "swimming",
            cues: ["swimming", "lap swimming", "swim"],
            assumption: "Assuming lap swimming in a pool.",
            parts: [
                (label: "Goggles", query: "swim goggles"),
                (label: "Swimsuit", query: "lap swimsuit"),
                (label: "Swim cap", query: "silicone swim cap"),
                (label: "Kickboard", query: "swim kickboard"),
                (label: "Towel", query: "quick dry swim towel"),
                (label: "Swim bag", query: "mesh swim bag"),
            ]
        ),

        // MARK: Pets, hobbies, self

        Recipe(
            id: "puppy",
            cues: ["puppy", "new dog", "dog essentials"],
            assumption: "Assuming a puppy coming home for the first time.",
            parts: [
                (label: "Crate", query: "dog crate"),
                (label: "Bed", query: "dog bed"),
                (label: "Collar and leash", query: "dog collar leash set"),
                (label: "Bowls", query: "dog food bowls"),
                (label: "Puppy food", query: "puppy food"),
                (label: "Chew toys", query: "puppy chew toys"),
            ]
        ),
        Recipe(
            id: "kitten",
            cues: ["kitten", "new cat", "cat essentials"],
            assumption: "Assuming an indoor cat settling in for the first time.",
            parts: [
                (label: "Litter box", query: "cat litter box"),
                (label: "Litter", query: "cat litter"),
                (label: "Carrier", query: "cat carrier"),
                (label: "Scratching post", query: "cat scratching post"),
                (label: "Bowls", query: "cat food bowls"),
                (label: "Toys", query: "cat toys"),
            ]
        ),
        Recipe(
            id: "art-supplies",
            cues: ["art supplies", "painting supplies", "drawing", "watercolor"],
            assumption: "Assuming a beginner setting up at home.",
            parts: [
                (label: "Sketchbook", query: "sketchbook"),
                (label: "Pencils", query: "drawing pencil set"),
                (label: "Paints", query: "watercolor paint set"),
                (label: "Brushes", query: "paint brush set"),
                (label: "Paper", query: "watercolor paper pad"),
                (label: "Easel", query: "tabletop easel"),
            ]
        ),
        Recipe(
            id: "skincare",
            cues: ["skincare routine", "skincare", "skin care"],
            assumption: "Assuming a simple daily routine rather than treatment for a specific concern.",
            parts: [
                (label: "Cleanser", query: "gentle facial cleanser"),
                (label: "Moisturizer", query: "facial moisturizer"),
                (label: "Sunscreen", query: "facial sunscreen spf 50"),
                (label: "Serum", query: "vitamin c serum"),
                (label: "Exfoliant", query: "chemical exfoliant"),
                (label: "Lip balm", query: "lip balm"),
            ]
        ),
    ]
}
