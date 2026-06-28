import SwiftUI
import CrumbKit

/// The taste profile sheet: how Crumb reads the user. Shown as a bottom sheet from the
/// header. Editable in spirit; the scaffold shows the default profile.
struct TasteProfileView: View {
    @Environment(AppModel.self) private var model

    private var profile: TasteProfile { model.tasteProfile }

    var body: some View {
        BottomSheet(
            title: "Your taste",
            subtitle: "How Crumb reads you",
            onClose: { model.isShowingTasteProfile = false }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xl) {
                signature
                chipSection(title: "Vibe", items: profile.vibe, tint: CrumbColor.pine)
                chipSection(title: "Leanings", items: profile.leanings, tint: CrumbColor.ink2)
                budget
            }
            .padding(.top, CrumbMetrics.Space.m)
        }
    }

    private var signature: some View {
        CuratorNote(profile.signatureLine, signoff: "Crumb")
    }

    private func chipSection(title: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text(title)
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)
            FlowChips(items: items, tint: tint)
        }
    }

    private var budget: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack {
                Text("Budget comfort")
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Spacer()
                Text(profile.budgetComfort, format: .percent.precision(.fractionLength(0)))
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                    .monospacedDigit()
            }
            ProgressView(value: profile.budgetComfort)
                .tint(CrumbColor.ochre)
            Text("Thrifty ↔ Splurge")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Budget comfort \(Int(profile.budgetComfort * 100)) percent")
    }
}

/// A simple wrapping row of pill chips.
struct FlowChips: View {
    let items: [String]
    var tint: Color = CrumbColor.pine

    var body: some View {
        FlexibleWrap(spacing: CrumbMetrics.Space.s) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(CrumbType.pill)
                    .foregroundStyle(tint)
                    .padding(.horizontal, CrumbMetrics.Space.m)
                    .padding(.vertical, CrumbMetrics.Space.s)
                    .background(CrumbColor.pineSoft, in: Capsule())
            }
        }
    }
}

/// A minimal flow layout that wraps its subviews onto multiple lines.
struct FlexibleWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rows.append(0)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
