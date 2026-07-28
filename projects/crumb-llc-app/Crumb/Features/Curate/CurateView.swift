import SwiftUI
import CrumbKit
import CrumbArt

/// A frozen, read-only product proposal. Add, Skip, and search adjustment live exclusively in the
/// response dock, so historical product turns can never remain accidentally actionable.
struct MissionProductSnapshotView: View {
    let snapshot: MissionProductSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            productArt
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(snapshot.title)
                        .font(CrumbType.title2)
                        .foregroundStyle(CrumbColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: CrumbMetrics.Space.s)
                    Text(snapshot.presentedPrice, format: .currency(code: "USD"))
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .monospacedDigit()
                        .fixedSize()
                }

                Text(snapshot.merchant)
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)

                if let variant = snapshot.variantTitle, !variant.isEmpty {
                    Label(variant, systemImage: "slider.horizontal.3")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink2)
                }

                Text(snapshot.rationale)
                    .font(CrumbType.curator)
                    .foregroundStyle(CrumbColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(snapshot.presentedAvailability)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)

                if let disclosure = snapshot.disclosure, !disclosure.isEmpty {
                    Text(disclosure)
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(CrumbMetrics.Space.l)
        }
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .crumbShadow(.lifted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("missionArtifact.product.\(snapshot.productID)")
    }

    @ViewBuilder
    private var productArt: some View {
        if let imageURL = snapshot.imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .empty: placeholder.overlay(ProgressView().tint(.white))
                case .failure: placeholder
                @unknown default: placeholder
                }
            }
            .frame(height: 150)
            .clipped()
            .accessibilityHidden(true)
        } else {
            placeholder
                .frame(height: 150)
                .clipped()
                .accessibilityHidden(true)
        }
    }

    private var placeholder: some View {
        ProductArt(
            stops: [0x315F5A, 0x8AB5A8],
            symbol: "shippingbox.fill",
            seed: snapshot.productID
        )
    }

    private var accessibilitySummary: String {
        var parts = [
            snapshot.title,
            snapshot.presentedPrice.formatted(.currency(code: "USD")),
            "from \(snapshot.merchant)",
        ]
        if let variant = snapshot.variantTitle, !variant.isEmpty { parts.append(variant) }
        parts.append(snapshot.presentedAvailability)
        if !snapshot.rationale.isEmpty { parts.append(snapshot.rationale) }
        return parts.joined(separator: ", ")
    }
}

/// Crumb's recommendation, with the two options that make it legible underneath.
///
/// The first product is the answer and gets the full card — photo, price, and the curator's
/// reason. The rest are foils, and they are deliberately *small*: three full cards is 1,300pt of
/// scrolling and turns a recommendation back into the price ladder this design exists to replace.
/// A foil states the one thing it is for — costs less, or is a step up — and what that costs.
struct MissionComparisonSnapshotView: View {
    let snapshot: MissionComparisonSnapshot

    private var recommendation: MissionProductSnapshot? { snapshot.products.first }
    private var foils: [MissionProductSnapshot] { Array(snapshot.products.dropFirst()) }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            if let recommendation {
                MissionProductSnapshotView(snapshot: recommendation)

                if !foils.isEmpty {
                    Text("Also considered")
                        .font(CrumbType.captionStrong)
                        .foregroundStyle(CrumbColor.ink3)
                        .padding(.top, CrumbMetrics.Space.xs)

                    VStack(spacing: 0) {
                        ForEach(Array(foils.enumerated()), id: \.element.productID) { index, foil in
                            if index > 0 { Divider().overlay(CrumbColor.line) }
                            MissionFoilRow(
                                snapshot: foil,
                                framing: foil.presentedPrice < recommendation.presentedPrice
                                    ? "Costs less" : "A step up"
                            )
                        }
                    }
                    .background(
                        CrumbColor.raised,
                        in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                            .strokeBorder(CrumbColor.line, lineWidth: 1)
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionArtifact.comparison.\(snapshot.id)")
    }
}

/// One alternative, at a glance. Read-only: choosing it happens in the dock, so scrollback can
/// never stay accidentally actionable — the same rule the full product card follows.
private struct MissionFoilRow: View {
    let snapshot: MissionProductSnapshot
    /// Why this row is here at all, in two words.
    let framing: String

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            art
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(framing)
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.pine)
                Text(snapshot.title)
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(snapshot.merchant)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .lineLimit(1)
            }

            Spacer(minLength: CrumbMetrics.Space.s)

            Text(snapshot.presentedPrice, format: .currency(code: "USD"))
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(CrumbMetrics.Space.m)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(framing): \(snapshot.title), \(snapshot.presentedPrice.formatted(.currency(code: "USD"))), from \(snapshot.merchant)"
        )
        .accessibilityIdentifier("missionFoil.\(snapshot.productID)")
    }

    @ViewBuilder
    private var art: some View {
        if let imageURL = snapshot.imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ProductArt(stops: [0x315F5A, 0x8AB5A8], symbol: "shippingbox.fill", seed: snapshot.productID)
    }
}
