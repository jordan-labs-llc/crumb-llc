import SwiftUI

/// A simple open "kit" — a rounded tote/basket with a handle — drawn as a stroked line
/// motif. The destination the breadcrumb trail leads to; used in the hero and empty states.
public struct KitBox: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let x = rect.minX, y = rect.minY

        // Body: a slightly tapered tote with a rounded base.
        let topY = y + h * 0.42
        let bodyTopInset = w * 0.06
        let baseInset = w * 0.16
        let r = w * 0.12

        path.move(to: CGPoint(x: x + bodyTopInset, y: topY))
        path.addLine(to: CGPoint(x: x + w - bodyTopInset, y: topY))
        path.addLine(to: CGPoint(x: x + w - baseInset, y: y + h - r))
        path.addQuadCurve(
            to: CGPoint(x: x + w - baseInset - r, y: y + h),
            control: CGPoint(x: x + w - baseInset, y: y + h)
        )
        path.addLine(to: CGPoint(x: x + baseInset + r, y: y + h))
        path.addQuadCurve(
            to: CGPoint(x: x + baseInset, y: y + h - r),
            control: CGPoint(x: x + baseInset, y: y + h)
        )
        path.closeSubpath()

        // Handle arc.
        let handleY = topY
        path.move(to: CGPoint(x: x + w * 0.30, y: handleY))
        path.addCurve(
            to: CGPoint(x: x + w * 0.70, y: handleY),
            control1: CGPoint(x: x + w * 0.34, y: y + h * 0.06),
            control2: CGPoint(x: x + w * 0.66, y: y + h * 0.06)
        )

        // Rim.
        path.move(to: CGPoint(x: x + bodyTopInset * 0.7, y: topY))
        path.addLine(to: CGPoint(x: x + w - bodyTopInset * 0.7, y: topY))
        return path
    }
}

/// The onboarding hero: a quiet editorial band — a diminishing breadcrumb trail leading to
/// a kit that holds a single warm crumb. The name's promise, drawn in one line.
public struct CrumbHeroArt: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [ArtPalette.pineSoft, ArtPalette.paper],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Breadcrumb trail of diminishing crumbs, left → right.
                ForEach(Array(trailDots(w: w, h: h).enumerated()), id: \.offset) { _, d in
                    CrumbGlyph(showsEdge: false, showsSpeckles: d.size > w * 0.05)
                        .frame(width: d.size, height: d.size)
                        .opacity(d.opacity)
                        .position(x: d.x, y: d.y)
                }

                // The kit, holding a crumb, at the trail's end.
                let kitW = w * 0.20
                ZStack {
                    KitBox()
                        .stroke(ArtPalette.pine, style: StrokeStyle(lineWidth: max(2, w * 0.006),
                                                                    lineCap: .round, lineJoin: .round))
                        .frame(width: kitW, height: kitW)
                    CrumbGlyph()
                        .frame(width: kitW * 0.4, height: kitW * 0.4)
                        .offset(y: kitW * 0.16)
                }
                .position(x: w * 0.82, y: h * 0.5)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityHidden(true)
    }

    private func trailDots(w: CGFloat, h: CGFloat) -> [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] {
        [
            (w * 0.12, h * 0.62, w * 0.045, 0.35),
            (w * 0.26, h * 0.52, w * 0.06, 0.5),
            (w * 0.40, h * 0.58, w * 0.075, 0.68),
            (w * 0.55, h * 0.48, w * 0.095, 0.9),
        ]
    }
}

/// Quiet, on-brand empty-state art for the Curate deck, replacing the lone SF Symbol.
public struct CrumbEmptyArt: View {
    public enum Variant { case kitReady, nothingYet }

    var variant: Variant

    public init(variant: Variant) {
        self.variant = variant
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(ArtPalette.pineSoft)
                .frame(width: 132, height: 132)

            switch variant {
            case .kitReady:
                // A kit holding a warm crumb — the mission resolved.
                ZStack {
                    KitBox()
                        .stroke(ArtPalette.pine, style: StrokeStyle(lineWidth: 3,
                                                                    lineCap: .round, lineJoin: .round))
                        .frame(width: 76, height: 76)
                    CrumbGlyph()
                        .frame(width: 30, height: 30)
                        .offset(y: 12)
                }
            case .nothingYet:
                // An empty kit, faint — nothing gathered yet.
                KitBox()
                    .stroke(ArtPalette.ink3, style: StrokeStyle(lineWidth: 3,
                                                                lineCap: .round, lineJoin: .round))
                    .frame(width: 76, height: 76)
                    .opacity(0.7)
            }
        }
        .accessibilityHidden(true)
    }
}
