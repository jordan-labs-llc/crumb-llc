import Foundation

/// Deterministic seed data that makes the skeleton "alive": three sample missions, their
/// candidate products, the shops behind them, and a default taste profile.
///
/// All money is whole-dollar `Decimal`. Art is an SF Symbol + a two-stop gradient drawn
/// from a small earthy palette (see ``Gradient``).
public enum SeedData {

    // MARK: - Gradient palette (packed-RGB hex stops for card art)

    public enum Gradient {
        public static let pine: [UInt32] = [0x27514A, 0x16332E]
        public static let earth: [UInt32] = [0x7A5A3A, 0x4F3A24]
        public static let stone: [UInt32] = [0x5D6552, 0x3B4035]
        public static let ochre: [UInt32] = [0xB9863F, 0x7E5A28]
    }

    // MARK: - Shops

    public enum Shops {
        public static let northbound = Shop(id: "northbound", name: "Northbound Supply")
        public static let cedarPine = Shop(id: "cedar-pine", name: "Cedar & Pine")
        public static let trailhead = Shop(id: "trailhead", name: "Trailhead Goods")
        public static let wolfCreek = Shop(id: "wolf-creek", name: "Wolf Creek")
        public static let ridgeline = Shop(id: "ridgeline", name: "Ridgeline")
        public static let fieldFlask = Shop(id: "field-flask", name: "Field & Flask")
        public static let millOak = Shop(id: "mill-oak", name: "Mill & Oak")
        public static let emberCoffee = Shop(id: "ember-coffee", name: "Ember Coffee Co.")
        public static let hearthForm = Shop(id: "hearth-form", name: "Hearth & Form")
    }

    // MARK: - Products

    /// Every seed product, keyed for lookup by `get_product`-style access.
    public static let products: [Product] = hikeProducts + coffeeProducts + deskProducts

    /// O(1) lookup table by product id.
    public static let productsByID: [Product.ID: Product] = Dictionary(
        uniqueKeysWithValues: products.map { ($0.id, $0) }
    )

    // MARK: Mission 1 — hike

    public static let hikeProducts: [Product] = [
        product("hike.shell", "Stormcaught Shell", Shops.northbound, 228, 4.8, 612,
                "Taped seams, matte slate — quiet, not loud-technical.",
                "cloud.rain", Gradient.pine),
        product("hike.midlayer", "Emberlight Down Midlayer", Shops.cedarPine, 164, 4.7, 430,
                "Packs to a fist and stays warm when damp.",
                "leaf", Gradient.earth),
        product("hike.runners", "Granite Trail Runners", Shops.trailhead, 145, 4.6, 1_240,
                "Grippy on wet rock; broken-in day one.",
                "shoeprints.fill", Gradient.stone),
        product("hike.socks", "Highland Merino Socks (2-pack)", Shops.wolfCreek, 34, 4.9, 980,
                "Merino, not synthetic — warm even when wet.",
                "shippingbox", Gradient.earth),
        product("hike.cap", "Dryline Rain Cap", Shops.northbound, 42, 4.5, 210,
                "Keeps the drizzle off your glasses.",
                "drop", Gradient.pine),
        product("hike.pack", "Switchback 18L Pack", Shops.ridgeline, 189, 4.7, 356,
                "Right size for two days, sits close to the back.",
                "mountain.2", Gradient.stone),
    ]

    // MARK: Mission 2 — coffee

    public static let coffeeProducts: [Product] = [
        product("coffee.kettle", "Heron Gooseneck Kettle", Shops.fieldFlask, 129, 4.8, 740,
                "A slow, steady pour you can actually aim — the whole ritual starts here.",
                "cup.and.saucer", Gradient.ochre),
        product("coffee.grinder", "Tabletop Burr Grinder", Shops.millOak, 185, 4.7, 510,
                "An even grind is the one upgrade you taste every single morning.",
                "gearshape.2", Gradient.stone),
        product("coffee.dripper", "Cloudware Ceramic Dripper", Shops.fieldFlask, 38, 4.6, 320,
                "Holds heat like a stone — simple, and it gets out of the way.",
                "cup.and.saucer", Gradient.ochre),
        product("coffee.beans", "Sunday Roast Beans (2 bags)", Shops.emberCoffee, 36, 4.9, 1_500,
                "A gentle medium roast I think you'll quietly fall for.",
                "leaf", Gradient.earth),
        product("coffee.mat", "Linen Brew Mat", Shops.millOak, 24, 4.5, 180,
                "Catches the drips and softens the whole corner.",
                "square.dashed", Gradient.earth),
    ]

    // MARK: Mission 3 — desk

    public static let deskProducts: [Product] = [
        product("desk.lamp", "Lowlight Desk Lamp", Shops.hearthForm, 148, 4.7, 290,
                "Warm, dimmable light — the opposite of an office ceiling.",
                "lamp.desk", Gradient.ochre),
        product("desk.tray", "Oak Catch-all Tray", Shops.millOak, 52, 4.8, 410,
                "One honest place for the clutter to land.",
                "tray", Gradient.earth),
        product("desk.mug", "Morningware Mug", Shops.fieldFlask, 28, 4.9, 1_100,
                "Heavy in the hand, the right kind of plain.",
                "cup.and.saucer", Gradient.stone),
        product("desk.mat", "Washed Linen Desk Mat", Shops.hearthForm, 46, 4.6, 220,
                "Soft texture underhand — quiets the whole surface.",
                "rectangle", Gradient.stone),
        product("desk.plant", "Trailing Pothos (potted)", Shops.cedarPine, 34, 4.7, 520,
                "One living thing. It forgives a missed watering.",
                "leaf", Gradient.pine),
    ]

    // MARK: - Missions

    public static let missions: [ShoppingTask] = [hike, coffee, desk]

    public static let hike = ShoppingTask(
        id: "hike",
        title: "Pack me for a rainy weekend hike",
        subtitle: "2 days · Cascades · warm + dry",
        plan: [
            "Waterproof shell",
            "Warm midlayer",
            "Grippy trail shoes",
            "Merino socks",
            "Rain cap",
            "Right-sized pack",
        ],
        curatorNote: "Rain's in the forecast all weekend, so I led with a real shell and "
            + "merino that stays warm even when it's soaked. Nothing bulky — you like to "
            + "move light.",
        accentHex: 0x1C4B43,
        candidateIDs: hikeProducts.map(\.id)
    )

    public static let coffee = ShoppingTask(
        id: "coffee",
        title: "Set up my pour-over corner",
        subtitle: "Slower mornings · better cup",
        plan: [
            "Gooseneck kettle",
            "Burr grinder",
            "Dripper",
            "Fresh beans",
            "A tidy mat",
        ],
        curatorNote: "A good pour-over comes down to a steady pour and an even grind. I "
            + "kept it to the four things that actually change the cup — plus a bag I "
            + "think you'll love.",
        accentHex: 0xCC8A3A,
        candidateIDs: coffeeProducts.map(\.id)
    )

    public static let desk = ShoppingTask(
        id: "desk",
        title: "Make my desk feel calm",
        subtitle: "Warm light · soft texture · less clutter",
        plan: [
            "Warm desk light",
            "Catch-all for clutter",
            "A mug you reach for",
            "Soft surface",
            "Something living",
        ],
        curatorNote: "You said calm, so I pulled warm light, soft texture, and one thing "
            + "to corral the clutter. Nothing shiny.",
        accentHex: 0x3F5A54,
        candidateIDs: deskProducts.map(\.id)
    )

    // MARK: - Taste profile

    public static let defaultTasteProfile = TasteProfile(
        vibe: ["Quiet", "Earthy", "Built to last"],
        leanings: ["Merino over synthetic", "Muted tones", "Fewer better things"],
        budgetComfort: 0.6,
        signatureLine: "You'd rather own three things you love than ten you tolerate."
    )

    // MARK: - Builder

    /// Builds a seed product with a single standard variant (no real checkout URL).
    private static func product(
        _ id: String,
        _ name: String,
        _ shop: Shop,
        _ price: Int,
        _ rating: Double,
        _ reviews: Int,
        _ rationale: String,
        _ symbol: String,
        _ gradient: [UInt32]
    ) -> Product {
        let amount = Decimal(price)
        return Product(
            id: id,
            name: name,
            shop: shop,
            price: amount,
            rating: rating,
            reviews: reviews,
            rationale: rationale,
            symbol: symbol,
            gradient: gradient,
            variants: [
                Variant(id: "\(id).standard", title: "Standard", price: amount)
            ]
        )
    }
}
