import SwiftUI
import CrumbKit

/// The taste profile sheet: how Crumb reads the user — now **editable**. Opened from the
/// header, it holds a working draft of the ``TasteProfile``; tapping Save persists it and
/// (when a deck is on screen) re-curates so the change is felt immediately. Closing without
/// saving discards the edits.
struct TasteProfileView: View {
    @Environment(AppModel.self) private var model

    /// A working copy edited in place; committed to the model only on Save.
    @State private var draft: TasteProfile

    init(initial: TasteProfile) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        BottomSheet(
            title: "Your taste",
            subtitle: "How Crumb reads you",
            onClose: { model.isShowingTasteProfile = false }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xl) {
                DescribeYourselfCard(draft: $draft)

                EditableChipSection(
                    title: "Vibe",
                    tint: CrumbColor.pine,
                    items: $draft.vibe,
                    suggestions: TasteVocabulary.vibe
                )
                EditableChipSection(
                    title: "Leanings",
                    tint: CrumbColor.ink2,
                    items: $draft.leanings,
                    suggestions: TasteVocabulary.leanings
                )
                BudgetComfortSlider(value: $draft.budgetComfort)
                SignatureEditor(text: $draft.signatureLine)

                saveButton
            }
            .padding(.top, CrumbMetrics.Space.m)
        }
    }

    private var saveButton: some View {
        Button {
            model.updateTaste(draft.normalized)
            model.isShowingTasteProfile = false
        } label: {
            HStack {
                Spacer()
                Text("Save taste")
                    .font(CrumbType.headline)
                Image(systemName: "checkmark")
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(CrumbMetrics.Space.l)
            .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .crumbShadow()
        }
        .buttonStyle(.plain)
        .padding(.top, CrumbMetrics.Space.s)
        .accessibilityIdentifier("saveTasteButton")
    }
}

// MARK: - Read-only chips (still used elsewhere)

/// A simple wrapping row of pill chips (non-editable).
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
