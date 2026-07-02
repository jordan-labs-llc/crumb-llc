import SwiftUI
import CrumbKit

/// **The signature component.** A translucent bar pinned at the bottom of the Curate
/// screen showing overlapping product thumbnails that animate in as items are added,
/// plus a live count, subtotal, and shop count. Tapping it opens the Cart.
///
/// This is the one bold element — everything else stays quiet. Animations honor
/// `accessibilityReduceMotion`.
struct KitTray: View {
    let items: [KitItem]
    /// When true the mission is a direct single-product search, so the tray reads as a shortlist to
    /// compare rather than a kit to assemble (#56).
    var isSingleProduct: Bool = false
    /// Called when the tray is tapped to open the cart.
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shopCount: Int {
        Set(items.map(\.product.shop.id)).count
    }

    private var subtotal: Decimal {
        items.reduce(0) { $0 + $1.variant.price }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: CrumbMetrics.Space.m) {
                thumbnails
                summary
                Spacer(minLength: CrumbMetrics.Space.s)
                openAffordance
            }
            .padding(CrumbMetrics.Space.m)
            .background(tray)
        }
        .buttonStyle(.plain)
        .disabled(items.isEmpty)
        .opacity(items.isEmpty ? 0.6 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: items.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(items.isEmpty ? "" : "Opens your kit")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Pieces

    private var thumbnails: some View {
        let shown = Array(items.suffix(4).enumerated())
        return ZStack(alignment: .leading) {
            if shown.isEmpty {
                Image(systemName: "bag")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
            }
            ForEach(shown, id: \.element.id) { index, item in
                thumbnail(for: item)
                    .offset(x: CGFloat(index) * 22)
                    .transition(reduceMotion
                        ? .opacity
                        : .scale.combined(with: .opacity))
            }
        }
        .frame(width: shown.isEmpty ? 34 : CGFloat(34 + (shown.count - 1) * 22), alignment: .leading)
        .accessibilityHidden(true)
    }

    private func thumbnail(for item: KitItem) -> some View {
        ProductThumbnail(
            product: item.product,
            size: 34,
            cornerRadius: 9,
            glyphSize: 14,
            strokeColor: .white.opacity(0.65),
            strokeWidth: 1.5
        )
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(titleLine)
                .font(CrumbType.pill)
                .foregroundStyle(.white)
            Text(secondaryLine)
                .font(CrumbType.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var openAffordance: some View {
        HStack(spacing: CrumbMetrics.Space.xs) {
            Text(subtotal, format: .currency(code: "USD"))
                .font(CrumbType.headline)
                .foregroundStyle(.white)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Empty: an invitation; filled: a live count. Shortlist wording for a single-product search,
    /// kit wording otherwise (#56).
    private var titleLine: String {
        if items.isEmpty { return isSingleProduct ? "Your shortlist" : "Your kit" }
        return isSingleProduct
            ? "^[\(items.count) option](inflect: true)"
            : "^[\(items.count) item](inflect: true)"
    }

    private var secondaryLine: String {
        if items.isEmpty { return isSingleProduct ? "Swipe right to shortlist" : "Swipe right to add" }
        let shops = shopCount == 1 ? "1 shop" : "\(shopCount) shops"
        return shops
    }

    private var tray: some View {
        RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
            .fill(CrumbColor.pine)
            .overlay(
                RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.18))
            )
            .crumbShadow(.lifted)
    }

    private var accessibilityLabel: String {
        guard !items.isEmpty else { return isSingleProduct ? "Your shortlist is empty" : "Your kit is empty" }
        let price = subtotal.formatted(.currency(code: "USD"))
        let shops = shopCount == 1 ? "1 shop" : "\(shopCount) shops"
        if isSingleProduct {
            let count = items.count == 1 ? "1 option" : "\(items.count) options"
            return "Shortlist, \(count) from \(shops), subtotal \(price)"
        }
        let count = items.count == 1 ? "1 item" : "\(items.count) items"
        return "Kit, \(count) from \(shops), subtotal \(price)"
    }
}

#Preview {
    KitTray(items: SeedData.hikeProducts.prefix(3).map(KitItem.init(product:))) {}
        .padding()
        .background(CrumbColor.paper)
}
