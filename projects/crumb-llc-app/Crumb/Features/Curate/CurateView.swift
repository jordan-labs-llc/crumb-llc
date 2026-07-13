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

struct MissionComparisonSnapshotView: View {
    let snapshot: MissionComparisonSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Text("Options to compare")
                .font(CrumbType.captionStrong)
                .foregroundStyle(CrumbColor.pine)
            ForEach(snapshot.products, id: \.productID) { product in
                MissionProductSnapshotView(snapshot: product)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionArtifact.comparison.\(snapshot.id)")
    }
}
