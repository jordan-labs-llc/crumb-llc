import Foundation

/// One recommendation and the two options worth putting next to it.
///
/// ## Why not just show the ranked list
///
/// The reported session showed five jasmine teas — `$18, $28, $32, $43.99, $58` — with no photo,
/// no reason, and one product listed twice. That is not a shortlist, it is a price ladder, and it
/// moves the whole job of deciding back onto the person who asked Crumb to decide.
///
/// So Crumb commits. `winner` is the pick, stated as an answer. `cheaper` and `nicer` are the two
/// foils that make that answer legible — they exist to show what you give up by spending less and
/// what you get by spending more, which is the comparison people actually make. Anything past three
/// is a list again.
///
/// ## Where the model stops and the floors start
///
/// The incoming order is the curator's — model-ranked, and that is where taste and voice belong.
/// This type never reorders on taste. It only enforces the things a ranking model gets wrong in
/// ways that are expensive:
///
/// - **Duplicates.** The same tea from the same shop appearing twice, which the report shows.
/// - **Distinctness.** A "cheaper" option that costs 50¢ less is not a choice, it is noise.
/// - **Price sanity.** A wildly-priced outlier presented as a peer — the `$1,450` black tea.
///
/// Pure and deterministic: the same candidates always produce the same shortlist.
public struct MissionShortlist: Hashable, Sendable {
    /// Crumb's answer.
    public let winner: Product
    /// A meaningfully less expensive option, when the candidates hold one.
    public let cheaper: Product?
    /// A meaningfully more expensive option, when the candidates hold one.
    public let nicer: Product?

    public init(winner: Product, cheaper: Product? = nil, nicer: Product? = nil) {
        self.winner = winner
        self.cheaper = cheaper
        self.nicer = nicer
    }

    /// Winner first, then the foils in price order. Never more than three, never a duplicate.
    public var all: [Product] { ([winner] + [cheaper, nicer].compactMap { $0 }) }

    /// The foils alone.
    public var foils: [Product] { [cheaper, nicer].compactMap { $0 } }

    /// True when there is genuinely nothing to compare — the caller should present the winner as a
    /// single product rather than as a comparison of one.
    public var isSolo: Bool { cheaper == nil && nicer == nil }

    // MARK: - Selection

    /// A foil has to differ by at least this share of the winner's price to be worth showing.
    /// Below it, the two options are the same decision at two prices.
    private static let minimumRelativeGap = Decimal(0.12)
    /// …or by at least this much in absolute terms, so cheap items aren't held to a pointless
    /// percentage (12% of $8 is a dollar).
    private static let minimumAbsoluteGap = Decimal(3)
    /// A candidate priced past this multiple of the winner is a catalog accident, not a nicer
    /// version of the same thing. Crumb has shipped a $1,450 tea into a cart before.
    private static let outlierMultiple = Decimal(4)

    /// Builds the shortlist from candidates **in the curator's ranked order**.
    ///
    /// Returns `nil` only when `candidates` is empty. A single candidate yields a solo shortlist
    /// rather than nothing — having one answer is still an answer.
    public static func choose(from candidates: [Product]) -> MissionShortlist? {
        let deduped = deduplicated(candidates)
        guard let winner = deduped.first else { return nil }

        let others = deduped.dropFirst().filter { isSanelyPriced($0, against: winner) }

        // Least expensive of the meaningfully-cheaper options: the foil answers "how little could
        // I spend here", so the nearest-cheaper is the least useful one to show.
        let cheaper = others
            .filter { $0.price < winner.price && isDistinct($0.price, from: winner.price) }
            .min { $0.price < $1.price }

        // Nearest of the meaningfully-pricier options: the foil answers "what does a bit more
        // buy", so the most expensive one is the least useful.
        let nicer = others
            .filter { $0.price > winner.price && isDistinct($0.price, from: winner.price) }
            .min { $0.price < $1.price }

        return MissionShortlist(winner: winner, cheaper: cheaper, nicer: nicer)
    }

    /// Two prices far enough apart to represent a real choice.
    private static func isDistinct(_ price: Decimal, from reference: Decimal) -> Bool {
        let gap = abs(price - reference)
        return gap >= minimumAbsoluteGap || gap >= reference * minimumRelativeGap
    }

    /// Guards the *upper* bound only. A genuinely cheap option is a useful foil; a wildly expensive
    /// one shown beside a $28 tea is a mistake wearing the same clothes as a recommendation.
    private static func isSanelyPriced(_ product: Product, against winner: Product) -> Bool {
        guard winner.price > 0 else { return true }
        return product.price <= winner.price * outlierMultiple
    }

    /// Drops repeats, keeping the earliest (best-ranked) occurrence.
    ///
    /// Product ids are matched first, but the reported session showed *"Dragon Pearl Jasmine ·
    /// Harney · $28.00"* twice in one view, which means distinct catalog ids for what a person
    /// reads as one product. So identity also folds on title + shop, which is what someone
    /// actually compares by.
    private static func deduplicated(_ products: [Product]) -> [Product] {
        var seenIDs = Set<Product.ID>()
        var seenIdentities = Set<String>()
        var kept: [Product] = []
        for product in products {
            guard seenIDs.insert(product.id).inserted else { continue }
            guard seenIdentities.insert(identity(of: product)).inserted else { continue }
            kept.append(product)
        }
        return kept
    }

    /// A person's sense of "the same product": the display title and who is selling it, folded for
    /// case, diacritics, and punctuation so "Dragon Pearl Jasmine" and "Dragon-Pearl jasmine" from
    /// one shop count once.
    static func identity(of product: Product) -> String {
        let title = TitleHygiene.display(for: product.name)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(product.shop.id)|\(title)"
    }
}
