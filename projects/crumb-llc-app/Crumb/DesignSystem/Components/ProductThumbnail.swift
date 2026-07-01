import SwiftUI
import CrumbKit

/// A small square product thumbnail used in the cart lines and the kit tray.
///
/// Mirrors ``ProductCard``'s art logic at thumbnail scale: it shows the real catalog photo
/// when the product carries one (``Product/artKind``), and falls back to the synthesized
/// gradient + SF Symbol glyph while the photo loads, when the load fails, or when there's no
/// image at all (seed data). Keeping the gradient+glyph as the fallback preserves the exact
/// look the cart and tray had before real photos existed.
struct ProductThumbnail: View {
    let product: Product
    /// Side length of the (square) thumbnail.
    var size: CGFloat
    var cornerRadius: CGFloat
    /// Point size of the fallback SF Symbol glyph.
    var glyphSize: CGFloat
    /// Optional hairline border (the tray draws a translucent white stroke; the cart none).
    var strokeColor: Color? = nil
    var strokeWidth: CGFloat = 0

    var body: some View {
        art
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if let strokeColor {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: strokeWidth)
                }
            }
    }

    @ViewBuilder
    private var art: some View {
        switch product.artKind {
        case .photo(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    fallback
                @unknown default:
                    fallback
                }
            }
        case .synthesized:
            fallback
        }
    }

    /// The synthesized gradient ground with the product's focal glyph — the same primitives
    /// the cart and tray used before, now serving as the photo's loading/failure fallback.
    private var fallback: some View {
        ZStack {
            LinearGradient(crumbStops: product.gradient)
            Image(systemName: product.symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
