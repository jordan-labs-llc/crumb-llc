import SwiftUI
import CrumbKit
import CrumbArt

/// **A past mission, reopened.** The read-only detail of one saved entry: the curator's recap and
/// note, the plan that was run, and the kit the user actually built (grouped by shop, with totals).
/// Two forward actions — *Re-shop* (re-present the snapshot's checkout links, honest about gone
/// ones) and *Plan this again* (route the goal back through the planner) — plus delete.
///
/// Everything here is a snapshot from save time: prices and links are the record, not a live fetch
/// (live UCP prices drift and `get_product` isn't exposed). A snapshot link may have since moved;
/// the re-shop sheet says so plainly rather than failing silently.
struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let entry = model.selectedHistoryEntry {
                content(entry)
            } else {
                // Defensive — the route is only entered with a selection.
                Color.clear.onAppear { model.openHistory() }
            }
        }
        .accessibilityIdentifier("HistoryDetailScreen")
    }

    private func content(_ entry: HistoryEntry) -> some View {
        let accent = Color(hex: entry.accentHex)
        return ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                recapHeader(entry, accent: accent)
                curatorNote(entry)
                planSection(entry)
                kitSection(entry, accent: accent)
                actions(entry, accent: accent)
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        .confirmationDialog(
            "Delete this mission?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.deleteHistoryEntry(entry) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This removes the saved record on this device. It can't be undone.")
        }
    }

    // MARK: Recap header

    private func recapHeader(_ entry: HistoryEntry, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack(spacing: CrumbMetrics.Space.s) {
                ZStack {
                    LinearGradient(colors: [accent, accent.opacity(0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    CrumbMark().fill(CrumbColor.paper.opacity(0.92)).padding(11)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.recapTag)
                        .font(CrumbType.title)
                        .foregroundStyle(CrumbColor.ink)
                    Text(entry.title)
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .lineLimit(1)
                }
            }

            if let recipient = entry.recipient {
                RecipientTag(name: recipient.name, accentHex: recipient.accentHex)
            }

            Text(entry.recapLine)
                .font(CrumbType.curatorTitle)
                .foregroundStyle(CrumbColor.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: CrumbMetrics.Space.s) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                if entry.handedOff {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Handed off to checkout")
                    }
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.pine)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Curator note

    @ViewBuilder
    private func curatorNote(_ entry: HistoryEntry) -> some View {
        if !entry.curatorNote.isEmpty {
            HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
                CrumbBadge(size: 22)
                Text(entry.curatorNote)
                    .font(CrumbType.curator)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .crumbCard()
        }
    }

    // MARK: Plan

    @ViewBuilder
    private func planSection(_ entry: HistoryEntry) -> some View {
        if !entry.plan.isEmpty {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                Text("The plan you ran")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink3)
                    .textCase(.uppercase)
                FlowChips(items: entry.plan, tint: CrumbColor.ink2)
            }
        }
    }

    // MARK: Kit (grouped by shop)

    private func kitSection(_ entry: HistoryEntry, accent: Color) -> some View {
        // Group by shop once per render (not re-derived inside the ForEach), and number items in a
        // flat running order so they cascade in nicely on open.
        let groups = entry.shops.map { (shop: $0, items: entry.items(for: $0)) }
        var ordinal = 0
        var order: [String: Int] = [:]
        for group in groups {
            for item in group.items { order[item.id] = ordinal; ordinal += 1 }
        }

        return VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack {
                Text("What you kept")
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Spacer()
                Text(entry.subtotal, format: .currency(code: "USD"))
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                    .monospacedDigit()
            }

            ForEach(groups, id: \.shop.id) { group in
                VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                    HStack(spacing: CrumbMetrics.Space.xs) {
                        Image(systemName: "storefront")
                            .font(.caption)
                            .foregroundStyle(accent)
                        Text(group.shop.name)
                            .font(CrumbType.captionStrong)
                            .foregroundStyle(CrumbColor.ink2)
                    }
                    ForEach(group.items) { item in
                        HistoryItemRow(item: item, accent: accent)
                            .crumbReveal(index: order[item.id] ?? 0, reduceMotion: reduceMotion)
                    }
                }
            }
        }
        .crumbCard()
    }

    // MARK: Actions

    private func actions(_ entry: HistoryEntry, accent: Color) -> some View {
        VStack(spacing: CrumbMetrics.Space.m) {
            Button {
                model.beginReshop(entry)
            } label: {
                actionLabel("Re-shop this kit", systemImage: "arrow.up.right", filled: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reshopButton")

            Button {
                model.planAgain(entry)
            } label: {
                actionLabel("Plan this again", systemImage: "sparkles", filled: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("planAgainButton")

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete this mission", systemImage: "trash")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink3)
                    .padding(.vertical, CrumbMetrics.Space.xs)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deleteHistoryButton")
        }
        .padding(.top, CrumbMetrics.Space.s)
    }

    private func actionLabel(_ title: String, systemImage: String, filled: Bool) -> some View {
        HStack {
            Spacer()
            Image(systemName: systemImage)
            Text(title).font(CrumbType.headline)
            Spacer()
        }
        .foregroundStyle(filled ? .white : CrumbColor.pine)
        .padding(.vertical, CrumbMetrics.Space.m)
        .background(
            filled ? AnyShapeStyle(CrumbColor.pine) : AnyShapeStyle(CrumbColor.raised),
            in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: filled ? 0 : 1)
        )
    }
}

// MARK: - Item row

/// One read-only kit line in the detail: an accent dot, the product name + variant, and the
/// snapshotted price.
struct HistoryItemRow: View {
    let item: HistoryItem
    let accent: Color

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            ZStack {
                accent.opacity(0.16)
                CrumbMark().fill(accent).padding(10)
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                // Cleaned display name; raw title kept on the a11y label for VoiceOver.
                Text(TitleHygiene.display(for: item.name))
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(1)
                    .accessibilityLabel(item.name)
                Text(item.variantTitle)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
            }

            Spacer(minLength: 0)

            Text(item.price, format: .currency(code: "USD"))
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Re-shop sheet

/// Re-shops a saved kit from its snapshot: per-shop sections, each item linking to the buy URL it
/// carried at save time. Honest about gone links — a snapshot URL may have moved or sold out, and a
/// missing one says so plainly rather than presenting a dead button (mirroring the checkout
/// handoff's "no link" honesty).
struct HistoryReshopView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    let entry: HistoryEntry

    var body: some View {
        BottomSheet(
            title: "Re-shop \(entry.recapTag)",
            subtitle: "Saved links, straight to each shop",
            onClose: { model.reshopEntry = nil }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                snapshotNote

                ForEach(entry.shops) { shop in
                    VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                        Text(shop.name)
                            .font(CrumbType.headline)
                            .foregroundStyle(CrumbColor.ink)
                        ForEach(entry.items(for: shop)) { item in
                            reshopRow(item)
                        }
                    }
                }
            }
        }
    }

    private var snapshotNote: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(CrumbColor.ink3)
                .accessibilityHidden(true)
            Text("These are the links from when you built this kit. Prices may have changed and "
                + "some items may have moved or sold out.")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reshopRow(_ item: HistoryItem) -> some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(TitleHygiene.display(for: item.name))
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink)
                    .accessibilityLabel(item.name)
                Text(item.price, format: .currency(code: "USD"))
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let url = item.buyURL {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(.white)
                    .padding(.horizontal, CrumbMetrics.Space.m)
                    .padding(.vertical, CrumbMetrics.Space.s)
                    .background(CrumbColor.pine, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(item.name) at \(item.shop.name)")
            } else {
                Text("No link")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ochre)
                    .padding(.horizontal, CrumbMetrics.Space.s)
                    .padding(.vertical, 6)
                    .background(CrumbColor.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(CrumbColor.line, lineWidth: 1))
                    .accessibilityLabel("\(item.name): no saved link")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
