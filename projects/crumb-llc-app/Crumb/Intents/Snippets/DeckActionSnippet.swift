import SwiftUI

/// The little card an App Intent hands back to Siri / Shortcuts after acting on a deck product —
/// so a hands-free "add this to my kit" (or "why this one?") shows a visual confirmation, not just
/// spoken text. Self-contained (plain values, no `AppModel` environment) so it renders reliably in
/// the system's intent UI. See issue #41.
struct DeckActionSnippet: View {
    let product: ProductEntity
    /// The action line ("Added to your kit") or, for Explain, the curator's rationale.
    let message: String
    /// An optional trailing summary, e.g. the kit count after an add.
    var kitSummary: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: product.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(product.name)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let kitSummary {
                    Text(kitSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
