import Foundation

/// A pure, deterministic, offline-safe policy for turning a **seller domain** into a shop-shaped
/// display name — the sibling of ``TitleHygiene`` for the merchant line rather than the product one.
///
/// The UCP catalog carries **no seller display name**. Verified against the live Global Catalog
/// (2026-07-27, 70 products over 8 queries): a product node's only top-level keys are
/// `id`, `title`, `description`, `media`, `options`, `price_range`, `variants` — there is no
/// `seller`, `vendor`, or `brand` anywhere in the payload. The broker derives `sellerDomain` from
/// the host of the variant's buy URL, so the host is genuinely all we have to render.
///
/// Rendered raw, that host reads as plumbing: `"$18.00 · harney.com"` looks unfinished next to a
/// product name. This helper produces `"Harney"` — and, where the domain honestly decomposes,
/// `"Golden Moon Tea"` from `goldenmoontea.com`.
///
/// **It never invents.** There is no network and no lookup table of brands. It only ever *removes*
/// domain plumbing (the public suffix, subdomains) and *re-spaces* what remains, and it is
/// deliberately conservative about the re-spacing: a label is only split when it decomposes
/// **completely** into known words (optionally after one unknown leading brand token), so
/// `northbound.com` stays `"Northbound"` rather than becoming a wrong "North Bound". When in doubt
/// it keeps the label whole — a slightly squashed name is honest, a mis-split one is not.
///
/// The raw domain is **never lost**: it remains `Shop.id`, which is what merchant grouping,
/// checkout, and the domain-matching curation heuristics key on. Only the display name changes.
public enum ShopNameHygiene {

    /// The shop-shaped display name for a seller domain, or `nil` when the domain yields nothing
    /// renderable (absent, blank, or pure punctuation) so the caller can fall back.
    ///
    /// - `"harney.com"` → `"Harney"`
    /// - `"www.rishi-tea.com"` → `"Rishi Tea"`
    /// - `"goldenmoontea.com"` → `"Golden Moon Tea"`
    /// - `"northbound.myshopify.com"` → `"Northbound"`
    /// - `"startfitness.co.uk"` → `"Start Fitness"`
    /// - `"stx.com"` → `"STX"`
    public static func display(for domain: String?) -> String? {
        guard let domain else { return nil }
        guard let label = registrableLabel(of: domain) else { return nil }

        let words = label
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .flatMap { segments(for: String($0)) }
            .map(capitalized)

        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    // MARK: - Domain → label

    /// The brand-bearing label of a host: the public suffix and every subdomain removed.
    /// `"shop.bombas.com"` → `"bombas"`, `"www.secondearth.com.au"` → `"secondearth"`.
    private static func registrableLabel(of domain: String) -> String? {
        // Tolerate a full URL or a host:port, not just the bare host the broker sends.
        var host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = host.range(of: "://") { host = String(host[schemeRange.upperBound...]) }
        host = String(host.prefix(while: { $0 != "/" && $0 != ":" && $0 != "?" }))

        let labels = host.split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return nil }

        // Strip the public suffix — two labels for a compound one (`co.uk`, and `myshopify.com`,
        // which really is a public suffix), otherwise one.
        var kept = labels
        if kept.count > 2, compoundSuffixes.contains("\(kept[kept.count - 2]).\(kept[kept.count - 1])") {
            kept.removeLast(2)
        } else if kept.count > 1 {
            kept.removeLast()
        }

        // What's left is `[subdomain…, brand]`; the brand is the last label. Taking it outright
        // beats an allowlist of generic subdomains — it handles `shop.`, `www.`, `eu.` and every
        // other prefix a merchant invents, without a list to maintain.
        let label = kept.last ?? labels.last
        guard let label, !label.isEmpty else { return nil }
        return label
    }

    /// Public suffixes that span two labels, so `startfitness.co.uk` keeps `startfitness` rather
    /// than collapsing to `co`. Not exhaustive — the storefront long tail, plus `myshopify.com`
    /// for the Shopify-hosted shops the catalog is full of.
    private static let compoundSuffixes: Set<String> = [
        "myshopify.com",
        "co.uk", "org.uk", "ac.uk", "me.uk",
        "com.au", "net.au", "org.au", "co.nz", "com.sg", "com.my", "co.th", "com.ph",
        "co.jp", "ne.jp", "co.kr", "com.tw", "com.hk", "com.cn", "co.in",
        "com.br", "com.mx", "com.ar", "com.co", "com.pe",
        "co.za", "co.il", "com.tr", "com.ua", "com.pl",
    ]

    // MARK: - Label → words

    /// Re-spaces a squashed label into words, or returns it whole when it doesn't decompose cleanly.
    ///
    /// Two shapes are accepted, in order: the label covers **entirely** with known words
    /// (`goldenmoontea` → golden·moon·tea), or an unknown **brand token** followed by a complete
    /// tail of known words (`yolohayoga` → yoloha·yoga). Anything else is left alone.
    private static func segments(for token: String) -> [String] {
        let characters = Array(token)
        // Short labels are brands, not sentences (`ooni`, `stx`); long ones aren't worth the search.
        guard (minSplitLength...maxSplitLength).contains(characters.count) else { return [token] }

        if let whole = cover(of: characters[...]) { return whole }

        // One unknown leading brand token. Shortest prefix first, so the *longest* known tail wins
        // (`lemsshoes` → lems·shoes, never lemssho·es — the tail words carry the meaning).
        for prefix in minWordLength...(characters.count - minWordLength) {
            if let tail = cover(of: characters[prefix...]) {
                return [String(characters[..<prefix])] + tail
            }
        }
        return [token]
    }

    /// A complete cover of `characters` by known words, or `nil` if none exists. Prefers the longest
    /// leading word but backtracks, so a greedy dead end still finds the real split
    /// (`theteamakers`: `team` strands `akers`, so it backs up to `tea` + `makers`).
    private static func cover(of characters: ArraySlice<Character>) -> [String]? {
        if characters.isEmpty { return [] }
        guard characters.count >= minWordLength else { return nil }

        var length = characters.count
        while length >= minWordLength {
            let split = characters.index(characters.startIndex, offsetBy: length)
            if knownWords.contains(String(characters[characters.startIndex..<split])),
               let rest = cover(of: characters[split...]) {
                return [String(characters[characters.startIndex..<split])] + rest
            }
            length -= 1
        }
        return nil
    }

    /// Shortest word we'll split out. Two-letter fragments (`ba`+`the`) are noise, not words.
    private static let minWordLength = 3
    /// Shortest label worth splitting; below this it's a brand (`ooni`, `harney`).
    private static let minSplitLength = 6
    /// Above this the search isn't worth running — a label that long is a slogan, not a name.
    private static let maxSplitLength = 40

    // MARK: - Casing

    /// Title-cases a word, keeping acronyms upper (`usa` → `USA`, `stx` → `STX`).
    private static func capitalized(_ word: String) -> String {
        guard !word.isEmpty else { return word }
        if isAcronym(word) { return word.uppercased() }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// Whether a word reads as an acronym: a known one, or a short all-consonant run — a
    /// pronounceable name needs a vowel, so `stx`/`vssl` are initialisms and `Stx`/`Vssl` would be
    /// plainly wrong. Length-bounded so a long consonant cluster isn't shouted.
    private static func isAcronym(_ word: String) -> Bool {
        if knownAcronyms.contains(word) { return true }
        guard (2...5).contains(word.count), word.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            return false
        }
        return !word.contains(where: { "aeiouy".contains($0) })
    }

    private static let knownAcronyms: Set<String> = ["usa", "uk", "eu", "uae", "nyc", "hq"]

    // MARK: - Vocabulary

    /// The words a squashed domain is allowed to decompose into: retail and category vocabulary plus
    /// the modifiers that pad brand names. Deliberately **not** a general English dictionary — the
    /// smaller and more commerce-shaped this list is, the fewer real brand names it can mangle.
    ///
    /// Safety rests on the full-cover rule in ``segments(for:)``, not on this list being complete:
    /// a word here only ever takes effect when the *entire* remaining label is also covered, so a
    /// stray match can't nibble a piece off a brand (`northbound` keeps `north` from firing because
    /// `bound` is not a word here). Missing a word costs a squashed name; adding a risky short one
    /// costs a wrong split — so when in doubt, leave it out.
    private static let knownWords: Set<String> = [
        // Retail & the shop itself
        "shop", "shops", "store", "stores", "market", "markets", "supply", "supplies", "company",
        "brand", "trading", "traders", "mercantile", "provisions", "collective", "goods", "outlet",
        "outfitters", "boutique", "emporium", "depot", "warehouse", "direct", "online", "club",
        "works", "studio", "labs", "house", "factory", "forge", "mill", "press", "maker", "makers",
        // Food & drink
        "tea", "teas", "coffee", "espresso", "brew", "brewing", "brewery", "roast", "roasted",
        "roasters", "roastery", "kettle", "cafe", "cocoa", "chocolate", "honey", "spice", "spices",
        "bakery", "farm", "farms", "garden", "gardens", "seed", "seeds", "food", "foods", "snack",
        "snacks", "flavour", "flavor",
        // Kitchen & home
        "kitchen", "cookware", "bakeware", "table", "ware", "cast", "iron", "skillet", "knife",
        "knives", "pots", "pans", "grill", "oven", "stove", "home", "living", "decor", "furniture",
        // Sport & outdoors
        "sport", "sports", "fitness", "athletic", "athletics", "running", "cycling", "bike", "bikes",
        "yoga", "outdoor", "outdoors", "camp", "camping", "hiking", "climbing", "trail", "trails",
        "surf", "snow", "lacrosse", "hockey", "soccer", "golf", "tennis", "basketball", "baseball",
        "fishing", "hunting", "archery",
        // Apparel & materials
        "apparel", "clothing", "wear", "socks", "shoes", "boots", "hats", "shirts", "denim",
        "merino", "wool", "cotton", "linen", "silk", "leather", "threads", "fashion", "style",
        // Body & botanicals
        "beauty", "skin", "skincare", "care", "soap", "candle", "candles", "scent", "fragrance",
        "botanicals", "herbs", "herbal", "apothecary", "wellness", "organic", "natural", "nature",
        // Gear & things
        "gear", "tools", "hardware", "parts", "spares", "accessories", "jewelry", "watches", "bags",
        "luggage", "optics", "audio", "electronics", "books", "paper", "print", "prints", "design",
        "craft", "crafts", "handmade", "toys", "baby", "kids", "pets",
        // Modifiers that pad brand names
        "the", "new", "little", "big", "great", "good", "best", "better", "fresh", "premium",
        "quality", "essential", "essentials", "signature", "universal", "alternative", "original",
        "origin", "simple", "honest", "true", "real", "wild", "free", "bold", "calm", "quiet",
        "bright", "dark", "light", "warm", "cool", "soft", "tough", "strong", "swift", "quick",
        "fast", "easy", "daily", "everyday", "latest", "drop", "first", "second", "third", "modern",
        "classic", "vintage", "urban", "pure", "eco", "plus", "mini", "micro", "ultra", "flow",
        // Place & nature words brands lean on
        "north", "south", "east", "west", "northern", "southern", "eastern", "western", "golden",
        "silver", "copper", "bronze", "moon", "star", "stars", "sun", "river", "mountain",
        "mountains", "forest", "field", "fields", "stone", "oak", "pine", "bay", "coast", "harbor",
        "lake", "valley", "summit", "peak", "ridge", "earth", "world", "globe", "island", "ocean",
        "village", "town", "city", "street", "road", "lane", "hill", "hills", "creek", "canyon",
        // People
        "man", "men", "women", "woman", "lady", "girl", "boy", "family", "people", "folk",
        "friends", "brothers", "sisters",
        // Places that read as words
        "usa",
    ]
}
