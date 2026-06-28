import SwiftUI

/// The curator "speaking" — serif voice copy in a quiet card with a small sparkle mark.
/// This is one of the few places the serif role is allowed.
struct CuratorNote: View {
    let text: String
    var signoff: String?
    var accent: Color = CrumbColor.pine

    init(_ text: String, signoff: String? = nil, accent: Color = CrumbColor.pine) {
        self.text = text
        self.signoff = signoff
        self.accent = accent
    }

    var body: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.m) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                Text(text)
                    .font(CrumbType.curator)
                    .foregroundStyle(CrumbColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if let signoff {
                    Text("— \(signoff)")
                        .font(CrumbType.curatorCaption)
                        .foregroundStyle(CrumbColor.ink2)
                }
            }
        }
        .crumbCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Crumb says: \(text)")
    }
}

#Preview {
    CuratorNote(
        "Rain's in the forecast all weekend, so I led with a real shell and merino that "
            + "stays warm even when it's soaked.",
        signoff: "Crumb"
    )
    .padding()
    .background(CrumbColor.paper)
}
