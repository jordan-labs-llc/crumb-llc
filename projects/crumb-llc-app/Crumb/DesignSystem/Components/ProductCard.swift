import SwiftUI
import CrumbKit
import CrumbArt

/// A product proposal card: gradient art with an SF Symbol, the name + shop + price, a
/// star rating, and the curator's serif rationale. The signature card on the deck.
struct ProductCard: View {
    let product: Product
    /// Shown when the item is already in the kit (e.g. an ochre check).
    var isInKit: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            art
            details
        }
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .crumbShadow(.lifted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var art: some View {
        ZStack {
            // Real product photo when the catalog carries one; the synthesized gradient +
            // symbol stands in while it loads and as the fallback when there's no image
            // (seed data) or the load fails.
            if let imageURL = product.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        placeholderArt.overlay(ProgressView().tint(.white))
                    case .failure:
                        placeholderArt
                    @unknown default:
                        placeholderArt
                    }
                }
                .accessibilityHidden(true)
            } else {
                placeholderArt
            }

            if isInKit {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(CrumbColor.ochre)
                            .padding(CrumbMetrics.Space.m)
                            .accessibilityHidden(true)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 220)
        .clipped()
    }

    /// The synthesized art used for seed products and as the loading/failure placeholder
    /// behind a real product photo: a refined gradient ground with topographic texture, a
    /// frosted focal glyph, and a quiet crumb watermark (see ``ProductArt``).
    private var placeholderArt: some View {
        ProductArt(stops: product.gradient, symbol: product.symbol, seed: product.id)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.name)
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
                Spacer()
                Text(product.price, format: .currency(code: "USD"))
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                    .monospacedDigit()
            }

            HStack(spacing: CrumbMetrics.Space.s) {
                Text(product.shop.name)
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                // Live catalog products carry no rating/review data; a "0.0 ★ (0)" reads as
                // a bad score, so we show stars only when there are real reviews to back them.
                if product.reviews > 0 {
                    RatingLabel(rating: product.rating, reviews: product.reviews)
                }
            }

            Text(product.rationale)
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, CrumbMetrics.Space.xs)
        }
        .padding(CrumbMetrics.Space.l)
    }

    private var accessibilitySummary: String {
        let price = product.price.formatted(.currency(code: "USD"))
        let kit = isInKit ? ", in your kit" : ""
        var summary = "\(product.name), \(price), from \(product.shop.name)"
        if product.reviews > 0 {
            let stars = product.rating.formatted(.number.precision(.fractionLength(1)))
            summary += ", rated \(stars) stars"
        }
        return summary + kit
    }
}

/// A compact star rating with review count. Ochre star = a small delight moment.
struct RatingLabel: View {
    let rating: Double
    let reviews: Int

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.xs) {
            Image(systemName: "star.fill")
                .foregroundStyle(CrumbColor.ochre)
                .imageScale(.small)
            Text(rating, format: .number.precision(.fractionLength(1)))
                .foregroundStyle(CrumbColor.ink)
            Text("(\(reviews))")
                .foregroundStyle(CrumbColor.ink3)
        }
        .font(CrumbType.caption)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating, specifier: "%.1f") out of 5, \(reviews) reviews")
    }
}
