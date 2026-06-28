import SwiftUI

/// A reusable bottom-sheet container: a grabber, a title row with a close button, and
/// scrollable content on a paper background. Used for the taste profile and the per-shop
/// checkout handoff. Pair with `.sheet`/`.presentationDetents` at the call site.
struct BottomSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(CrumbColor.ink3.opacity(0.5))
                .frame(width: 38, height: 5)
                .padding(.top, CrumbMetrics.Space.m)
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CrumbType.title2)
                        .foregroundStyle(CrumbColor.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(CrumbType.callout)
                            .foregroundStyle(CrumbColor.ink2)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(CrumbColor.ink3)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.top, CrumbMetrics.Space.m)
            .padding(.bottom, CrumbMetrics.Space.s)

            ScrollView {
                content()
                    .padding(.horizontal, CrumbMetrics.Space.xl)
                    .padding(.bottom, CrumbMetrics.Space.xl)
            }
        }
        .background(CrumbColor.paper)
    }
}

#Preview {
    BottomSheet(title: "Your taste", subtitle: "How Crumb reads you", onClose: {}) {
        Text("Content goes here")
            .font(CrumbType.body)
    }
}
