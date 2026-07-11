import SwiftUI

/// Crumb's guided-path mark, selected from the app-icon concept exploration.
///
/// Two torn pieces almost meet, while the pine negative space between them forms a winding
/// path. The silhouette keeps the warmth of the original crumb but connects it to Crumb's
/// core promise: guiding someone from an open-ended mission to a considered choice.
public struct CrumbPathMark: View {
    public enum Layer { case complete, left, right }

    var layer: Layer

    public init(layer: Layer = .complete) {
        self.layer = layer
    }

    public var body: some View {
        ZStack {
            if layer != .right {
                CrumbPathHalf(side: .left)
                    .fill(fill)
            }
            if layer != .left {
                CrumbPathHalf(side: .right)
                    .fill(fill)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var fill: LinearGradient {
        LinearGradient(
            colors: [ArtPalette.crumbLit, ArtPalette.ochre],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct CrumbPathHalf: Shape {
    enum Side { case left, right }
    let side: Side

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        var path = Path()
        switch side {
        case .left:
            path.move(to: point(0.49, 0.08))
            path.addLine(to: point(0.34, 0.06))
            path.addCurve(to: point(0.08, 0.38),
                          control1: point(0.20, 0.10), control2: point(0.10, 0.23))
            path.addLine(to: point(0.06, 0.55))
            path.addCurve(to: point(0.34, 0.88),
                          control1: point(0.10, 0.74), control2: point(0.20, 0.84))
            path.addLine(to: point(0.43, 0.90))
            path.addCurve(to: point(0.53, 0.64),
                          control1: point(0.51, 0.80), control2: point(0.56, 0.70))
            path.addCurve(to: point(0.36, 0.46),
                          control1: point(0.51, 0.58), control2: point(0.36, 0.55))
            path.addCurve(to: point(0.50, 0.22),
                          control1: point(0.36, 0.38), control2: point(0.50, 0.30))
            path.addCurve(to: point(0.49, 0.08),
                          control1: point(0.50, 0.16), control2: point(0.49, 0.12))
        case .right:
            path.move(to: point(0.61, 0.08))
            path.addCurve(to: point(0.94, 0.39),
                          control1: point(0.77, 0.09), control2: point(0.90, 0.23))
            path.addLine(to: point(0.96, 0.52))
            path.addCurve(to: point(0.70, 0.85),
                          control1: point(0.92, 0.70), control2: point(0.84, 0.80))
            path.addCurve(to: point(0.53, 0.91),
                          control1: point(0.64, 0.89), control2: point(0.58, 0.91))
            path.addCurve(to: point(0.62, 0.64),
                          control1: point(0.62, 0.80), control2: point(0.65, 0.70))
            path.addCurve(to: point(0.45, 0.46),
                          control1: point(0.60, 0.58), control2: point(0.45, 0.55))
            path.addCurve(to: point(0.58, 0.22),
                          control1: point(0.45, 0.38), control2: point(0.57, 0.30))
            path.addCurve(to: point(0.61, 0.08),
                          control1: point(0.59, 0.16), control2: point(0.60, 0.12))
        }
        path.closeSubpath()
        return path
    }
}

/// Platform composition for the guided-path mark.
/// iOS is full bleed, while macOS supplies its own transparent icon margin.
public struct CrumbAppIcon: View {
    public enum Style { case iOS, macOS }

    var style: Style

    public init(style: Style = .iOS) {
        self.style = style
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let margin = style == .macOS ? side * 0.085 : 0
            let inner = side - margin * 2
            let corner = inner * 0.2237

            ZStack {
                iconGround
                CrumbPathMark()
                    .frame(width: inner * (style == .macOS ? 0.76 : 0.72),
                           height: inner * (style == .macOS ? 0.76 : 0.72))
            }
            .frame(width: inner, height: inner)
            .clipShape(RoundedRectangle(cornerRadius: style == .macOS ? corner : 0,
                                        style: .continuous))
            .padding(margin)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var iconGround: some View {
        LinearGradient(
            colors: [ArtPalette.pineLift, ArtPalette.pine, ArtPalette.pineDeep],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// A miniature of the app mark used beside Crumb's in-app wordmark.
public struct CrumbBadge: View {
    var size: CGFloat

    public init(size: CGFloat = 26) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [ArtPalette.pineLift, ArtPalette.pine],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            CrumbPathMark()
                .frame(width: size * 0.66, height: size * 0.66)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Individual visionOS icon layers. The system supplies the circular mask, depth, and shadow.
public struct CrumbVisionIconLayer: View {
    public enum Kind { case back, left, right }

    var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var body: some View {
        ZStack {
            if kind == .back {
                LinearGradient(
                    colors: [ArtPalette.pineLift, ArtPalette.pineDeep],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.clear
                CrumbPathMark(layer: kind == .left ? .left : .right)
                    .frame(width: 680, height: 680)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}
