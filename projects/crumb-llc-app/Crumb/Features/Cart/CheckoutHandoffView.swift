import SwiftUI
import CrumbKit

/// The per-shop checkout handoff sheet. Shows the shop's items and a button that opens
/// the merchant's own secure checkout via the UCP `continue_url`.
///
/// In this scaffold the URL is a mock (non-routable) target — there is no real checkout.
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

                Button {
                    openURL(handoff.url)
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
                    + "(Mock target in this build — no real purchase is made.)")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
