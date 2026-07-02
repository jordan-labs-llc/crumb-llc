import SwiftUI
import CrumbKit

/// The Cart: the kit grouped by shop, with a per-shop "Continue to {shop}" handoff —
/// honest to what's GA today (no unified one-tap checkout).
struct CartView: View {
    @Environment(AppModel.self) private var model

    private var cart: Cart { model.currentCart }

    var body: some View {
        if cart.items.isEmpty {
            emptyState
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // A direct single-product search shows its shortlisted alternatives to compare and buy one;
        // a multi-part kit stays grouped by shop for its per-shop handoff (#60).
        if model.isSingleProductMission { singleContent } else { groupedContent }
    }

    private var groupedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                header

                // Readiness before checkout: for a complete-kit mission, say which plan categories
                // the kit still misses so a partial cart (three sticks, no pads/helmet) is never
                // framed as a finished kit (#67).
                if let completeness = model.kitCompleteness {
                    KitReadinessPanel(completeness: completeness) { model.back() }
                }

                ForEach(cart.shops) { shop in
                    ShopGroup(
                        shop: shop,
                        items: cart.items(for: shop),
                        subtotal: cart.subtotal(for: shop),
                        onRemove: { model.removeFromKit($0) },
                        onContinue: { Task { await model.beginHandoff(for: shop) } }
                    )
                }

                handoffNote
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        .safeAreaInset(edge: .bottom) { totalBar }
        .accessibilityIdentifier("CartScreen")
    }

    /// The single-product cart: a flat list of the shortlisted options, each with its own "Buy this"
    /// handoff, so the user knowingly picks one instead of being handed a surprise multi-shop kit.
    private var singleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                header

                Text("These are alternatives — pick the one you want and check out at its shop.")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("compareHint")

                ForEach(cart.items) { item in
                    CompareCard(
                        item: item,
                        onBuy: { Task { await model.beginHandoff(for: item) } },
                        onRemove: { model.removeFromKit(item) }
                    )
                }

                handoffNote
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        .safeAreaInset(edge: .bottom) { totalBar }
        .accessibilityIdentifier("CartScreen")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
            Text(model.isSingleProductMission ? "Your shortlist" : "Your kit")
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)
            Text(model.isSingleProductMission
                ? "Comparing ^[\(cart.items.count) option](inflect: true) · ^[\(cart.shops.count) shop](inflect: true)"
                : "^[\(cart.items.count) item](inflect: true) · ^[\(cart.shops.count) shop](inflect: true)")
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink2)
        }
    }

    private var handoffNote: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: "lock.shield")
                .foregroundStyle(CrumbColor.ink3)
            Text("Checkout hands off to each shop's own secure checkout. You'll confirm "
                + "payment with the merchant — Crumb never sees your card.")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, CrumbMetrics.Space.s)
    }

    private var totalBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                // Single-product: a price *range* over the alternatives — summing options the user
                // will pick one of would be misleading. Kit: the real subtotal of everything.
                Text(model.isSingleProductMission ? "^[\(cart.items.count) option](inflect: true)" : "Kit subtotal")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                Text(model.isSingleProductMission ? priceRangeText : cart.subtotal.formatted(.currency(code: "USD")))
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
                    .monospacedDigit()
            }
            Spacer()
            Text(model.isSingleProductMission ? "Pick one to check out" : "Continue per shop above")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
        }
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.vertical, CrumbMetrics.Space.m)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }

    /// The shortlist's price spread, e.g. "$24.00–$31.00" (or a single price when they match).
    private var priceRangeText: String {
        guard let range = cart.priceRange else { return "" }
        let low = range.min.formatted(.currency(code: "USD"))
        guard range.min != range.max else { return low }
        return "\(low)–\(range.max.formatted(.currency(code: "USD")))"
    }

    private var emptyState: some View {
        VStack(spacing: CrumbMetrics.Space.l) {
            Spacer()
            Image(systemName: "bag")
                .font(.system(size: 52))
                .foregroundStyle(CrumbColor.ink3)
            Text("Your kit is empty")
                .font(CrumbType.title2)
                .foregroundStyle(CrumbColor.ink)
            Button("Back to curating") { model.back() }
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.pine)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("CartScreen")
    }
}

/// The kit-readiness panel (#67): for a complete-kit mission, a calm "kit covers the plan" when the
/// checklist is satisfied, or a prominent "still missing …" warning naming the concrete categories
/// the kit lacks, with a "Keep curating" action. Per-shop checkout stays available below either way —
/// this is a pre-handoff readiness signal, not a block.
struct KitReadinessPanel: View {
    let completeness: KitCompleteness
    let onKeepCurating: () -> Void

    var body: some View {
        if completeness.isComplete {
            HStack(spacing: CrumbMetrics.Space.s) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(CrumbColor.pine)
                    .accessibilityHidden(true)
                Text("Your kit covers the plan — ^[all \(completeness.requiredCount) part](inflect: true).")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(CrumbMetrics.Space.m)
            .background(CrumbColor.pineSoft, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kitReady")
        } else {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                HStack(spacing: CrumbMetrics.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CrumbColor.ochre)
                        .accessibilityHidden(true)
                    Text("Your kit may be incomplete")
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                    Spacer(minLength: 0)
                }
                Text("Still missing: \(completeness.missing.joined(separator: ", "))")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("kitMissingList")
                Text("You can keep curating to fill the gaps, or continue per shop below.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onKeepCurating) {
                    HStack(spacing: CrumbMetrics.Space.xs) {
                        Image(systemName: "rectangle.stack")
                        Text("Keep curating")
                    }
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.pine)
                }
                .buttonStyle(.plain)
                .padding(.top, CrumbMetrics.Space.xs)
                .accessibilityIdentifier("keepCuratingButton")
            }
            .padding(CrumbMetrics.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CrumbColor.ochre.opacity(0.12), in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kitCompletenessWarning")
        }
    }
}

/// One shop's section in the cart: its items and a "Continue to {shop}" handoff button.
struct ShopGroup: View {
    let shop: Shop
    let items: [KitItem]
    let subtotal: Decimal
    let onRemove: (KitItem) -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack {
                Image(systemName: "storefront")
                    .foregroundStyle(CrumbColor.pine)
                Text(shop.name)
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Spacer()
                Text(subtotal, format: .currency(code: "USD"))
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                    .monospacedDigit()
            }

            ForEach(items) { item in
                CartLine(item: item, onRemove: { onRemove(item) })
            }

            Button(action: onContinue) {
                HStack {
                    Spacer()
                    Text("Continue to \(shop.name)")
                        .font(CrumbType.headline)
                    Image(systemName: "arrow.up.right")
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, CrumbMetrics.Space.m)
                .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("continue.\(shop.id)")
            .accessibilityHint("Hands off to \(shop.name)'s secure checkout")
        }
        .crumbCard()
    }
}

/// A single line item with a remove control.
struct CartLine: View {
    let item: KitItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            ProductThumbnail(product: item.product, size: 44, cornerRadius: 10, glyphSize: 18)

            VStack(alignment: .leading, spacing: 1) {
                // Cleaned display name; the raw title stays on the a11y label so VoiceOver reads it
                // in full. Two lines keeps a long name legible in the cart line.
                Text(TitleHygiene.display(for: item.product.name))
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(2)
                    .accessibilityLabel(item.product.name)
                Text(item.variant.title)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
            }

            Spacer()

            Text(item.variant.price, format: .currency(code: "USD"))
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink)
                .monospacedDigit()

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(CrumbColor.ink3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.product.name)")
        }
        .accessibilityElement(children: .combine)
    }
}

/// One shortlisted option in the single-product cart (#60): the product, its shop + rating + price,
/// a prominent "Buy this at {shop}" handoff, and a remove control — so the user compares the
/// alternatives inline and knowingly checks out one, instead of a surprise multi-merchant kit.
struct CompareCard: View {
    let item: KitItem
    let onBuy: () -> Void
    let onRemove: () -> Void

    private var product: Product { item.product }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack(spacing: CrumbMetrics.Space.m) {
                ProductThumbnail(product: product, size: 56, cornerRadius: 12, glyphSize: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(TitleHygiene.display(for: product.name))
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .lineLimit(2)
                        .accessibilityLabel(product.name)
                    HStack(spacing: CrumbMetrics.Space.xs) {
                        Image(systemName: "storefront")
                            .font(.caption2)
                            .foregroundStyle(CrumbColor.ink3)
                            .accessibilityHidden(true)
                        Text(product.shop.name)
                            .font(CrumbType.caption)
                            .foregroundStyle(CrumbColor.ink2)
                        // Seed products carry ratings; live catalog products read 0 and stay quiet.
                        if product.rating > 0 {
                            Text("· ★ " + product.rating.formatted(.number.precision(.fractionLength(1))))
                                .font(CrumbType.caption)
                                .foregroundStyle(CrumbColor.ink2)
                        }
                    }
                }

                Spacer(minLength: CrumbMetrics.Space.s)

                VStack(alignment: .trailing, spacing: CrumbMetrics.Space.xs) {
                    Text(item.variant.price, format: .currency(code: "USD"))
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .monospacedDigit()
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(CrumbColor.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(product.name)")
                }
            }

            Button(action: onBuy) {
                HStack {
                    Spacer()
                    Text("Buy this at \(product.shop.name)")
                        .font(CrumbType.headline)
                    Image(systemName: "arrow.up.right")
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, CrumbMetrics.Space.m)
                .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("buy.\(product.id)")
            .accessibilityHint("Hands off to \(product.shop.name)'s secure checkout for this item")
        }
        .crumbCard()
        .accessibilityElement(children: .contain)
    }
}
