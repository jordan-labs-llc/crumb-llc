import SwiftUI

/// Refined product-card art that replaces the bare two-stop gradient + flat SF Symbol.
///
/// Built from the same palette language as the rest of the brand: a multi-stop diagonal
/// ground with a top-light and corner vignette, a faint topographic contour texture
/// (seeded per product, so cards don't look stamped from one mold), a soft frosted focal
/// disc carrying the product glyph, and a small crumb watermark in the corner.
///
/// It takes only primitives (gradient hex stops + an SF Symbol name + a seed string), so it
/// stays free of the catalog model and serves equally as seed-product art and as the
/// loading/failure fallback behind a real product photo.
public struct ProductArt: View {
    var stops: [UInt32]
    var symbol: String
    var seed: String

    public init(stops: [UInt32], symbol: String, seed: String) {
        self.stops = stops
        self.symbol = symbol
        self.seed = seed
    }

    private var colors: [Color] {
        switch stops.count {
        case 0: return [ArtPalette.pine, ArtPalette.pineDeep]
        case 1: return [Color(hex: stops[0]), Color(hex: stops[0])]
        default: return stops.map { Color(hex: $0) }
        }
    }

    /// A stable 0..1 jitter from the seed, so each product's contours sit differently.
    private var jitter: CGFloat {
        let h = seed.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return CGFloat(h % 1000) / 1000.0
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Ground: top-lit diagonal gradient between the product's stops.
                LinearGradient(
                    colors: [colors.first!.lighten(0.12), colors.first!, colors.last!],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Topographic contour texture — earthy, quiet, seeded per product.
                contours(in: geo.size)
                    .stroke(Color.white.opacity(0.10), lineWidth: max(1, w * 0.004))

                // Corner vignette for depth.
                RadialGradient(
                    colors: [.clear, ArtPalette.ink.opacity(0.22)],
                    center: .center,
                    startRadius: w * 0.28,
                    endRadius: w * 0.72
                )

                // Focal glyph on a soft frosted disc.
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.55)
                        .frame(width: h * 0.46, height: h * 0.46)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                    Image(systemName: symbol)
                        .font(.system(size: h * 0.2, weight: .regular))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .shadow(color: ArtPalette.ink.opacity(0.18), radius: h * 0.03, y: h * 0.012)

                // Quiet crumb watermark, bottom-right.
                CrumbGlyph(showsEdge: false, showsSpeckles: false)
                    .frame(width: w * 0.12, height: w * 0.12)
                    .opacity(0.16)
                    .position(x: w - w * 0.12, y: h - w * 0.1)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    /// Three nested topographic contour rings, offset by the seed jitter.
    private func contours(in size: CGSize) -> Path {
        var path = Path()
        let cx = size.width * (0.32 + jitter * 0.36)
        let cy = size.height * (0.30 + jitter * 0.30)
        let base = max(size.width, size.height)
        for i in 0..<4 {
            let r = base * (0.26 + CGFloat(i) * 0.16)
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        }
        return path
    }
}

extension Color {
    /// Lightens toward white by `amount` (0…1) — a cheap top-light without a second token.
    func lighten(_ amount: Double) -> Color {
        let r = resolveComponents()
        return Color(.sRGB,
                     red: r.0 + (1 - r.0) * amount,
                     green: r.1 + (1 - r.1) * amount,
                     blue: r.2 + (1 - r.2) * amount,
                     opacity: 1)
    }

    /// Best-effort sRGB component read (falls back to mid-grey if the platform can't resolve).
    private func resolveComponents() -> (Double, Double, Double) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b))
        }
        #elseif canImport(AppKit)
        if let c = NSColor(self).usingColorSpace(.sRGB) {
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        #endif
        return (0.5, 0.5, 0.5)
    }
}
