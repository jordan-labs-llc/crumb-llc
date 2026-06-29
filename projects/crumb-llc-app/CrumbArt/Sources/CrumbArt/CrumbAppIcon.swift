import SwiftUI

/// The Crumb app icon: a single warm ``CrumbGlyph`` resting on a deep pine ground, lit from
/// the top, with a faint breadcrumb trail of dots curving up to it — the play on the name.
///
/// One composition drives both platforms:
///   • ``Style/iOS`` — full-bleed square; the system masks the corners.
///   • ``Style/macOS`` — content inset and clipped to the continuous "squircle" with a
///     transparent margin, the way a native macOS icon sits on the desktop.
public struct CrumbAppIcon: View {
    public enum Style { case iOS, macOS }

    var style: Style

    public init(style: Style = .iOS) {
        self.style = style
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            content(side: side)
                .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func content(side: CGFloat) -> some View {
        let margin = style == .macOS ? side * 0.085 : 0
        let inner = side - margin * 2
        let corner = inner * 0.2237  // Apple's superellipse corner ratio

        ZStack {
            ground(side: inner)
            trail(side: inner)
            CrumbGlyph()
                .frame(width: inner * 0.52, height: inner * 0.52)
                .shadow(color: ArtPalette.pineDeep.opacity(0.45),
                        radius: inner * 0.035, x: 0, y: inner * 0.02)
                .offset(y: -inner * 0.015)
        }
        .frame(width: inner, height: inner)
        .clipShape(RoundedRectangle(cornerRadius: style == .macOS ? corner : 0,
                                    style: .continuous))
        .padding(margin)
    }

    /// Deep pine ground with a top-light glow and a soft corner vignette for depth.
    private func ground(side: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [ArtPalette.pineLift, ArtPalette.pine, ArtPalette.pineDeep],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.white.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: side * 0.62
            )
            RadialGradient(
                colors: [.clear, ArtPalette.pineDeep.opacity(0.45)],
                center: .center,
                startRadius: side * 0.34,
                endRadius: side * 0.78
            )
        }
    }

    /// A breadcrumb trail: three warm flecks that look like bits broken off the crumb,
    /// curving down toward the lower-left — the play on the name.
    private func trail(side: CGFloat) -> some View {
        // x, y (unit), diameter, warmth (0 = shade … 1 = lit)
        let flecks: [(CGFloat, CGFloat, CGFloat, Double)] = [
            (0.30, 0.78, 0.052, 0.9),
            (0.23, 0.85, 0.034, 0.6),
            (0.165, 0.90, 0.022, 0.4),
        ]
        return ZStack {
            ForEach(Array(flecks.enumerated()), id: \.offset) { _, d in
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [ArtPalette.crumbLit, ArtPalette.ochre],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: d.2 * side, height: d.2 * side)
                    .opacity(0.45 + d.3 * 0.5)
                    .shadow(color: ArtPalette.pineDeep.opacity(0.4),
                            radius: d.2 * side * 0.2, x: 0, y: d.2 * side * 0.12)
                    .position(x: d.0 * side, y: d.1 * side)
            }
        }
        .frame(width: side, height: side)
    }
}

/// The in-app brand badge: the icon in miniature — a warm crumb on a pine disc — that
/// replaces the old `leaf.circle.fill` wordmark so the in-app mark and the home-screen
/// icon read as one brand.
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
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
            CrumbGlyph(showsEdge: false, showsSpeckles: size >= 22)
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
