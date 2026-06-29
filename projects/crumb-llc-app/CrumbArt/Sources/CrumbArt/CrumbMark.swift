import SwiftUI

/// The Crumb mark: a single, slightly irregular rounded "crumb" silhouette — an organic
/// pebble of bread, never a perfect circle. Defined in a unit box and mapped into the
/// supplied rect, so it scales cleanly from a 16-pt header badge to a 1024-px app icon.
///
/// This is the brand's atom: the app icon, the in-app wordmark badge, the card glyphs, and
/// the empty/hero scenes are all built from it.
public struct CrumbMark: Shape {
    public init() {}

    /// Torn-bread silhouette: irregular and faceted, heavier toward the base, with a notched
    /// top (the `0.50` peak dips below its neighbours) so it reads as a *broken piece*, not a
    /// smooth pebble. Tuned by hand.
    private static let unitVertices: [CGPoint] = [
        CGPoint(x: 0.34, y: 0.13),
        CGPoint(x: 0.50, y: 0.17),  // notch — the torn top
        CGPoint(x: 0.63, y: 0.10),
        CGPoint(x: 0.81, y: 0.23),
        CGPoint(x: 0.90, y: 0.44),
        CGPoint(x: 0.83, y: 0.66),
        CGPoint(x: 0.61, y: 0.81),
        CGPoint(x: 0.39, y: 0.85),
        CGPoint(x: 0.18, y: 0.71),
        CGPoint(x: 0.11, y: 0.46),
        CGPoint(x: 0.21, y: 0.26),
    ]

    public func path(in rect: CGRect) -> Path {
        let pts = Self.unitVertices.map {
            CGPoint(x: rect.minX + $0.x * rect.width,
                    y: rect.minY + $0.y * rect.height)
        }
        // Lower corner-rounding than a pebble keeps the facets/torn edges crisp.
        return Self.roundedPolygon(pts, cornerFraction: 0.24)
    }

    /// Rounds a closed polygon by replacing each vertex with a quadratic curve between the
    /// midpoint-ward points of its two edges — a soft, continuous pebble outline.
    static func roundedPolygon(_ points: [CGPoint], cornerFraction: CGFloat) -> Path {
        var path = Path()
        let n = points.count
        guard n >= 3 else { return path }
        let f = min(max(cornerFraction, 0), 0.5)

        for i in 0..<n {
            let prev = points[(i - 1 + n) % n]
            let curr = points[i]
            let next = points[(i + 1) % n]

            let start = CGPoint(x: curr.x + (prev.x - curr.x) * f,
                                y: curr.y + (prev.y - curr.y) * f)
            let end = CGPoint(x: curr.x + (next.x - curr.x) * f,
                              y: curr.y + (next.y - curr.y) * f)

            if i == 0 {
                path.move(to: start)
            } else {
                path.addLine(to: start)
            }
            path.addQuadCurve(to: end, control: curr)
        }
        path.closeSubpath()
        return path
    }
}

/// The warm crumb glyph: the ``CrumbMark`` filled with a lit→shaded warm gradient, a soft
/// top-left highlight, a thin toasted edge, and a few darker speckles for crumb texture.
/// The signature graphic — reused at every scale.
public struct CrumbGlyph: View {
    /// Draw the toasted edge stroke (drop on very small sizes where it muddies).
    var showsEdge: Bool
    /// Draw the speckle texture (drop on very small sizes).
    var showsSpeckles: Bool

    public init(showsEdge: Bool = true, showsSpeckles: Bool = true) {
        self.showsEdge = showsEdge
        self.showsSpeckles = showsSpeckles
    }

    public var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let mark = CrumbMark()
            let w = geo.size.width
            ZStack {
                // Warm crumb body — golden, lit top-left, toasting toward a darker base.
                mark.fill(
                    LinearGradient(
                        colors: [ArtPalette.crumbLit, ArtPalette.ochre, ArtPalette.crust],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                // A single hard-edged facet: darkens the lower-right half along a straight
                // break line, so the crumb reads as a *broken chunk* catching light — not a
                // smooth potato.
                facet(in: geo.size)
                    .fill(ArtPalette.crust)
                    .opacity(0.30)
                    .blendMode(.multiply)
                    .clipShape(mark)

                // Soft top-left highlight on the lit facet to round the form.
                mark
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.55), .clear],
                            center: UnitPoint(x: 0.33, y: 0.36),
                            startRadius: 0,
                            endRadius: w * 0.42
                        )
                    )
                    .blendMode(.softLight)

                if showsSpeckles {
                    // One small air-pocket high on the lit face — a hint of open crumb,
                    // never a row of "eyes".
                    Ellipse()
                        .fill(ArtPalette.crust.opacity(0.26))
                        .blendMode(.multiply)
                        .frame(width: w * 0.085, height: w * 0.055)
                        .rotationEffect(.degrees(-20))
                        .position(x: w * 0.56, y: w * 0.41)
                }

                if showsEdge {
                    mark.strokeBorder(
                        ArtPalette.crust.opacity(0.42),
                        lineWidth: max(1, w * 0.009)
                    )
                }
            }
            .compositingGroup()
            .frame(width: rect.width, height: rect.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// A large triangle covering the lower-right, its hypotenuse running upper-right →
    /// lower-left. Clipped to the mark, it becomes the crumb's shaded broken facet.
    private func facet(in size: CGSize) -> Path {
        var path = Path()
        let w = size.width, h = size.height
        path.move(to: CGPoint(x: w * 0.96, y: h * 0.26))
        path.addLine(to: CGPoint(x: w * 1.05, y: h * 1.05))
        path.addLine(to: CGPoint(x: w * 0.16, y: h * 1.05))
        path.closeSubpath()
        return path
    }
}

extension Shape {
    /// Strokes the shape's border inset by half the line width, so the stroke stays inside
    /// the fill (mirrors `InsettableShape.strokeBorder` for non-insettable shapes).
    func strokeBorder(_ color: Color, lineWidth: CGFloat) -> some View {
        self.stroke(color, lineWidth: lineWidth)
    }
}
