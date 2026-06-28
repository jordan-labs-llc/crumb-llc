import SwiftUI
import CrumbKit

/// A small pill that labels where a result came from — the honest "API tag".
///
/// Used to mark promoted (affiliate) placements distinctly from organic ones, and to
/// surface that data rides on UCP. Quiet by default; ochre only for promoted.
struct ApiTag: View {
    enum Style {
        case neutral
        case promoted
        case info
    }

    let label: String
    let systemImage: String?
    var style: Style = .neutral

    init(_ label: String, systemImage: String? = nil, style: Style = .neutral) {
        self.label = label
        self.systemImage = systemImage
        self.style = style
    }

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(label)
        }
        .font(CrumbType.captionStrong)
        .foregroundStyle(foreground)
        .padding(.horizontal, CrumbMetrics.Space.s)
        .padding(.vertical, CrumbMetrics.Space.xs)
        .background(background, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var foreground: Color {
        switch style {
        case .neutral: CrumbColor.ink2
        case .promoted: CrumbColor.ochre
        case .info: CrumbColor.pine
        }
    }

    private var background: Color {
        switch style {
        case .neutral: CrumbColor.line
        case .promoted: Color(hex: 0xCC8A3A, opacity: 0.15)
        case .info: CrumbColor.pineSoft
        }
    }

    private var accessibilityLabel: String {
        switch style {
        case .promoted: "Promoted: \(label)"
        default: label
        }
    }
}

extension ApiTag {
    /// A tag for a catalog placement.
    init(placement: Placement) {
        switch placement {
        case .organic:
            self.init("Organic", systemImage: "leaf", style: .neutral)
        case .affiliate:
            self.init("Promoted", systemImage: "megaphone", style: .promoted)
        }
    }
}

#Preview {
    HStack {
        ApiTag(placement: .organic)
        ApiTag(placement: .affiliate)
        ApiTag("UCP Catalog", systemImage: "bag", style: .info)
    }
    .padding()
    .background(CrumbColor.paper)
}
