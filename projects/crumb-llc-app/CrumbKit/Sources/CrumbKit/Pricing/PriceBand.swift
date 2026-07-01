import Foundation

/// A per-mission price sanity band, computed from the candidate set, that keeps a wildly mispriced
/// catalog outlier — a $1,450 "Premium Black Tea Leaf" in a deck whose norm is $4–$60 — out of the
/// top of the deck. The curator ranks by *fit*, and on live products (ratings/reviews absent) it
/// will happily float a confidently-named outlier into the top-3, so this is the deterministic
/// backstop that runs *after* ranking, in every curator tier, offline included.
///
/// The band is a robust **median ± k·MAD** (median absolute deviation): robust because a single
/// absurd price barely moves the median or the MAD, unlike a mean/standard-deviation the outlier
/// would drag toward itself. We only ever demote the **high** side (a suspiciously cheap item is
/// usually a welcome deal, not a decoy), and only when a candidate clears *both* an additive bar
/// (`> median + k·MAD`) and a multiplicative one (`> guardMultiple × median`) — so a tight, sane
/// distribution with one modestly pricier pick never over-fires, while a ~70× item always does.
///
/// Demotion is intentionally a **reorder, not a drop**: outliers keep their place in the pool but
/// sink to the tail, so they can never lead or land in the top-3 yet remain reachable behind the
/// in-band cards (the seam a future "show pricier options" affordance hangs off).
public struct PriceBand: Sendable, Equatable {
    public let median: Double
    /// The effective spread: the MAD, floored so an all-same-price set (MAD 0) doesn't classify
    /// every slightly-higher item as an outlier.
    public let spread: Double
    /// The high cut — a price strictly above this is a mispriced outlier.
    public let highCut: Double

    public init(median: Double, spread: Double, highCut: Double) {
        self.median = median
        self.spread = spread
        self.highCut = highCut
    }

    /// Builds a band from a candidate set, or `nil` when there are too few priced items to judge a
    /// norm (`< minCount`) — below that a handful of prices has no reliable middle and we never
    /// demote. `k` sets the additive width; `guardMultiple` the multiplicative floor (so only items
    /// many times the median are ever cut, never a merely wide-but-sane spread). Pure.
    public static func from(
        _ products: [Product],
        k: Double = 6,
        minCount: Int = 4,
        guardMultiple: Double = 10
    ) -> PriceBand? {
        let prices = products
            .map { NSDecimalNumber(decimal: $0.price).doubleValue }
            .filter { $0 > 0 }
        guard prices.count >= minCount else { return nil }
        let med = median(prices)
        guard med > 0 else { return nil }
        let mad = median(prices.map { abs($0 - med) })
        // Floor the spread so a near-zero MAD (tightly clustered prices) doesn't make every
        // slightly-above-median item an "outlier"; 10% of the median is a sane minimum width.
        let spread = Swift.max(mad, med * 0.10)
        // The cut is the *more permissive* of the two bars, so an item must be both far in absolute
        // MAD terms and a large multiple of the median before we treat it as mispriced.
        let cut = Swift.max(med + k * spread, med * guardMultiple)
        return PriceBand(median: med, spread: spread, highCut: cut)
    }

    /// Whether a product sits above the band's high cut — a mispriced outlier we keep out of the top.
    public func isHighOutlier(_ product: Product) -> Bool {
        NSDecimalNumber(decimal: product.price).doubleValue > highCut
    }

    /// Stably moves high outliers to the tail of `deck`, preserving order within the in-band group
    /// and within the outlier group. In-band items keep their ranked order and lead; outliers
    /// follow, deprioritized but still reachable. Pure.
    public func demotingOutliers(_ deck: [Product]) -> [Product] {
        let inBand = deck.filter { !isHighOutlier($0) }
        let outliers = deck.filter { isHighOutlier($0) }
        return inBand + outliers
    }

    /// The one call the app makes on a settled deck: compute the band from the deck itself and sink
    /// its price outliers to the tail, returning the deck unchanged when there are too few items to
    /// judge a band. Pure — so a mispriced item can never enter the top of the deck. Pure.
    public static func priceSane(_ deck: [Product]) -> [Product] {
        guard let band = from(deck) else { return deck }
        return band.demotingOutliers(deck)
    }

    // MARK: - Pure stats

    /// The median of `values` — the average of the two middles for an even count. Returns 0 for an
    /// empty input (the callers guard non-empty). Pure.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        if n.isMultiple(of: 2) { return (sorted[n / 2 - 1] + sorted[n / 2]) / 2 }
        return sorted[n / 2]
    }
}
