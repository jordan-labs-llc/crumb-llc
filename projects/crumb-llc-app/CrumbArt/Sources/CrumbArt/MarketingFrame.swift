import SwiftUI

/// A store-style marketing frame: a headline + serif subhead over a device-framed app
/// screenshot, on the Crumb paper board. Rendered to PNG by `crumb-art-market` so the
/// marketing shots stay reproducible from the same vector pipeline as the icon.
///
/// The `shot` is supplied as a ready SwiftUI `Image` (the tool loads the PNG), keeping this
/// view platform-agnostic.
public struct MarketingFrame: View {
    var shot: Image
    var headline: String
    var subhead: String
    var accent: Color

    /// Canvas size — a generous portrait marketing card.
    public static let canvas = CGSize(width: 1320, height: 2860)

    public init(shot: Image, headline: String, subhead: String, accent: Color = ArtPalette.pine) {
        self.shot = shot
        self.headline = headline
        self.subhead = subhead
        self.accent = accent
    }

    public var body: some View {
        let size = Self.canvas
        ZStack {
            // Warm board with a faint accent glow up top.
            ArtPalette.paper
            RadialGradient(
                colors: [accent.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: size.width * 0.9
            )

            VStack(spacing: 0) {
                // Wordmark.
                HStack(spacing: 14) {
                    CrumbBadge(size: 64)
                    Text("Crumb")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .foregroundStyle(ArtPalette.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 92)

                // Headline + serif subhead.
                VStack(alignment: .leading, spacing: 18) {
                    Text(headline)
                        .font(.system(size: 92, weight: .bold, design: .rounded))
                        .foregroundStyle(ArtPalette.ink)
                        .lineSpacing(2)
                    Text(subhead)
                        .font(.system(size: 44, design: .serif).italic())
                        .foregroundStyle(ArtPalette.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 40)

                Spacer(minLength: 60)

                // Device-framed screenshot, bleeding off the bottom edge.
                shot
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width * 0.72)
                    .clipShape(RoundedRectangle(cornerRadius: 64, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 64, style: .continuous)
                            .strokeBorder(ArtPalette.ink.opacity(0.08), lineWidth: 2)
                    )
                    .shadow(color: ArtPalette.ink.opacity(0.22), radius: 60, x: 0, y: 34)
                    .padding(.bottom, -180)
            }
            .padding(.horizontal, 96)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
