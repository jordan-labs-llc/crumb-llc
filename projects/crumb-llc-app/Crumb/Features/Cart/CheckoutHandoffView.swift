import SwiftUI
import CrumbKit

/// The per-shop checkout handoff sheet. Shows the shop's items and a button that opens
/// the merchant's own secure checkout via the UCP `continue_url` (or the merchant
/// storefront fallback). When no handoff target exists, it says so plainly rather than
/// presenting a dead button.
struct CheckoutHandoffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    let handoff: AppModel.Handoff

    private var subtotal: Decimal {
        handoff.items.reduce(0) { $0 + $1.variant.price }
    }

    var body: some View {
        BottomSheet(
            title: "Continue to \(handoff.shop.name)",
            subtitle: "Secure checkout, handled by the shop",
            onClose: { model.handoff = nil }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                ForEach(handoff.items) { item in
                    HStack {
                        Text(item.product.name)
                            .font(CrumbType.body)
                            .foregroundStyle(CrumbColor.ink)
                        Spacer()
                        Text(item.variant.price, format: .currency(code: "USD"))
                            .font(CrumbType.body)
                            .foregroundStyle(CrumbColor.ink2)
                            .monospacedDigit()
                    }
                }

                Divider().overlay(CrumbColor.line)

                HStack {
                    Text("Subtotal")
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                    Spacer()
                    Text(subtotal, format: .currency(code: "USD"))
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .monospacedDigit()
                }

                if let url = handoff.url {
                    Button {
                        // Opening a real checkout link is the honest "handed off" signal — flip
                        // this session's history entry's outcome flag (a no-link handoff doesn't).
                        model.recordHandoffFollowed()
                        openURL(url)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "lock.fill")
                            Text("Continue to \(handoff.shop.name)")
                                .font(CrumbType.headline)
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(CrumbMetrics.Space.l)
                        .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("handoffContinue")

                    Text("This hands off to \(handoff.shop.name)'s own secure checkout. "
                        + "You'll confirm payment with the merchant — Crumb never sees your card.")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    noHandoff
                }
            }
        }
    }

    /// Shown when no handoff target could be resolved for this shop — honest about the
    /// gap instead of a button that does nothing.
    private var noHandoff: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(CrumbColor.ochre)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No checkout link yet")
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Text("\(handoff.shop.name) hasn't shared a checkout link for these items. "
                    + "Try again later, or search for them on the shop's site.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("handoffUnavailable")
    }
}
