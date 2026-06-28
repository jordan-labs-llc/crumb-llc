import SwiftUI

/// Layout tokens: corner radii, the spacing scale, and soft shadows.
enum CrumbMetrics {

    /// Corner radii.
    enum Radius {
        static let card: CGFloat = 20
        static let tile: CGFloat = 12
        /// Fully rounded "pill".
        static let pill: CGFloat = 999
    }

    /// Spacing scale (4 / 8 / 12 / 16 / 22).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 22
    }

    /// A soft, low-contrast shadow token.
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        static let soft = Shadow(
            color: Color(hex: 0x221E18, opacity: 0.10),
            radius: 14,
            x: 0,
            y: 8
        )

        static let lifted = Shadow(
            color: Color(hex: 0x221E18, opacity: 0.16),
            radius: 22,
            x: 0,
            y: 14
        )
    }
}

extension View {
    /// Applies a Crumb shadow token.
    func crumbShadow(_ shadow: CrumbMetrics.Shadow = .soft) -> some View {
        self.shadow(
            color: shadow.color,
            radius: shadow.radius,
            x: shadow.x,
            y: shadow.y
        )
    }

    /// Wraps content as a Crumb card: raised surface, card radius, hairline, soft shadow.
    func crumbCard(padding: CGFloat = CrumbMetrics.Space.l) -> some View {
        self
            .padding(padding)
            .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                    .strokeBorder(CrumbColor.line, lineWidth: 1)
            )
            .crumbShadow()
    }
}
