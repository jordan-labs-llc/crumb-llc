import SwiftUI
import CrumbKit
import CrumbArt

/// **The History timeline.** A delightful, persistent record of past missions — each card pairs the
/// plan the user ran with the kit they built. Grouped by time (Today / This week / Earlier), topped
/// by an aggregate stats header with a subtle milestone moment, and tinted per-mission. Tapping a
/// card opens its read-only detail (``HistoryDetailView``).
///
/// Reached from the app header's clock affordance. When there's no history yet, it shows a warm,
/// on-brand first-run state instead.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingClear = false

    /// Grouped into time buckets relative to *now* (the view layer is where wall-clock is allowed —
    /// the grouping itself is pure and tested with an injected date).
    private var sections: [HistorySection] {
        HistoryTimeline.sections(model.filteredHistoryEntries, now: Date())
    }

    /// The per-recipient filter chips, shown only once there's at least one gift kit (so a user
    /// who never shops for anyone else never sees the control).
    private var facets: [HistoryRecipientFacet] { model.historyFacets }
    private var showsFilter: Bool {
        facets.contains { if case .person = $0.filter { return true } else { return false } }
    }

    /// The name to title the stats header with when a person/you filter is active ("For Mom"); `nil`
    /// for the unfiltered "All" view.
    private var activeFilterName: String? {
        switch model.historyRecipientFilter {
        case .all: return nil
        case .yourself: return "You"
        case let .person(id): return facets.first { $0.filter == .person(id) }?.label
        }
    }

    var body: some View {
        Group {
            if model.historyEntries.isEmpty {
                emptyState
            } else {
                timeline
            }
        }
        .accessibilityIdentifier("HistoryScreen")
        .confirmationDialog(
            "Clear your whole history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This removes every saved mission on this device. It can't be undone.")
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        List {
            Section {
                HistoryStatsHeader(stats: model.historyStats, filterName: activeFilterName)
                    .plainHistoryRow()
                    .padding(.bottom, CrumbMetrics.Space.xs)
            }

            if showsFilter {
                Section {
                    HistoryFilterRow(
                        facets: facets,
                        selected: model.historyRecipientFilter,
                        onSelect: { model.historyRecipientFilter = $0 }
                    )
                    .plainHistoryRow()
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            model.openHistoryDetail(entry)
                        } label: {
                            HistoryCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .plainHistoryRow()
                        .crumbReveal(index: index, reduceMotion: reduceMotion)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.deleteHistoryEntry(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                model.deleteHistoryEntry(entry)
                            } label: {
                                Label("Delete this mission", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(section.bucket.rawValue)
                        .font(CrumbType.captionStrong)
                        .foregroundStyle(CrumbColor.ink3)
                        .textCase(.uppercase)
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("Clear history", systemImage: "trash")
                        .font(CrumbType.callout)
                        .foregroundStyle(CrumbColor.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CrumbMetrics.Space.s)
                }
                .buttonStyle(.plain)
                .plainHistoryRow()
                .accessibilityIdentifier("clearHistoryButton")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("HistoryTimeline")
    }

    // MARK: Empty / first-run state

    private var emptyState: some View {
        VStack(spacing: CrumbMetrics.Space.l) {
            Spacer()
            CrumbEmptyArt(variant: .nothingYet)
            Text("No missions yet")
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)
            Text("Every kit you build lands here — the plan you ran and the things you kept, "
                + "kept for you to look back on, re-shop, or plan again.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CrumbMetrics.Space.xl)
            Button {
                model.goToMissions()
            } label: {
                Text("Start a mission")
                    .font(CrumbType.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, CrumbMetrics.Space.xl)
                    .padding(.vertical, CrumbMetrics.Space.m)
                    .background(CrumbColor.pine, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, CrumbMetrics.Space.s)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .accessibilityIdentifier("HistoryEmpty")
    }
}

// MARK: - Stats header

/// The aggregate "since you started" header: kits · items · shops · since <month>, with a subtle,
/// tasteful ochre milestone moment on round kit counts (5 / 10 / 25 / 50) — a quiet nod, never gamey.
struct HistoryStatsHeader: View {
    let stats: HistoryStats
    /// When a per-recipient filter is active, the header names whose record this is ("For Mom").
    var filterName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Text(filterName.map { "For \($0)" } ?? "Your missions")
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)

            HStack(alignment: .top, spacing: 0) {
                stat(value: "\(stats.kitCount)", label: stats.kitCount == 1 ? "kit" : "kits",
                     tint: stats.isMilestone ? CrumbColor.ochre : CrumbColor.ink)
                statDivider
                stat(value: "\(stats.itemCount)", label: stats.itemCount == 1 ? "item" : "items",
                     tint: CrumbColor.ink)
                statDivider
                stat(value: "\(stats.shopCount)", label: stats.shopCount == 1 ? "shop" : "shops",
                     tint: CrumbColor.ink)
            }

            if let since = stats.since {
                Text("Since \(since.formatted(.dateTime.month(.wide).year()))")
                    .font(CrumbType.curatorCaption)
                    .foregroundStyle(CrumbColor.ink2)
            }

            if stats.isMilestone {
                HStack(spacing: CrumbMetrics.Space.xs) {
                    CrumbBadge(size: 16)
                    Text("\(stats.kitCount) kits curated — a nice round number.")
                        .font(CrumbType.curatorCaption)
                        .foregroundStyle(CrumbColor.ochre)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("historyMilestone")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .crumbCard()
        .accessibilityElement(children: .contain)
    }

    private func stat(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(CrumbType.display)
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label)
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private var statDivider: some View {
        Rectangle()
            .fill(CrumbColor.line)
            .frame(width: 1, height: 34)
            .padding(.horizontal, CrumbMetrics.Space.s)
    }
}

// MARK: - History card

/// One rich, per-mission-tinted card on the timeline: the crafted recap tag, the curator-voice
/// recap line (serif), a meta row (items · shops · subtotal · when), and a quiet "handed off" mark.
struct HistoryCard: View {
    let entry: HistoryEntry

    private var accent: Color { Color(hex: entry.accentHex) }

    var body: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.m) {
            thumbnail

            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
                Text(entry.recapTag)
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(1)

                if let recipient = entry.recipient {
                    RecipientTag(name: recipient.name, accentHex: recipient.accentHex)
                }

                Text(entry.recapLine)
                    .font(CrumbType.curator)
                    .foregroundStyle(CrumbColor.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metaRow
            }
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            // A slim per-mission accent spine down the card's left edge.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4)
                .padding(.vertical, CrumbMetrics.Space.l)
        }
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .crumbShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// An accent-tinted thumbnail carrying the brand crumb mark — on-brand art, not an SF-symbol
    /// placeholder, and tinted by the mission's own accent.
    private var thumbnail: some View {
        ZStack {
            LinearGradient(
                colors: [accent, accent.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            CrumbMark()
                .fill(CrumbColor.paper.opacity(0.92))
                .padding(15)
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
        .accessibilityHidden(true)
    }

    private var metaRow: some View {
        HStack(spacing: CrumbMetrics.Space.xs) {
            // One truncatable unit so a narrow card never wraps the counts mid-phrase.
            (
                Text("^[\(entry.itemCount) item](inflect: true) · ^[\(entry.shopCount) shop](inflect: true) · ")
                    .foregroundStyle(CrumbColor.ink3)
                + Text(entry.subtotal, format: .currency(code: "USD"))
                    .foregroundStyle(CrumbColor.ink2)
            )
            .font(CrumbType.caption)
            .monospacedDigit()
            .lineLimit(1)

            Spacer(minLength: CrumbMetrics.Space.xs)

            if entry.handedOff {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(CrumbColor.pine)
                    .accessibilityHidden(true)
            }
            Text(entry.createdAt.formatted(.relative(presentation: .named)))
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
                .fixedSize()
        }
        .padding(.top, 2)
    }

    private var accessibilityText: String {
        let handed = entry.handedOff ? ", handed off to checkout" : ""
        let forWhom = entry.recipient.map { ", a gift for \($0.name)" } ?? ""
        return "\(entry.recapTag)\(forWhom). \(entry.recapLine). "
            + "\(entry.itemCount) items, \(entry.shopCount) shops\(handed)."
    }
}

// MARK: - Recipient tag + filter row

/// A small "for <name>" chip tinted by the recipient's accent — the gift attribution on a History
/// card and in the detail header.
struct RecipientTag: View {
    let name: String
    let accentHex: UInt32

    private var accent: Color { Color(hex: accentHex) }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gift.fill")
                .font(.system(size: 9, weight: .bold))
            Text("for \(name)")
                .font(CrumbType.captionStrong)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, CrumbMetrics.Space.s)
        .padding(.vertical, 3)
        .background(accent.opacity(0.12), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// The horizontal per-recipient filter chips at the top of the timeline (All · You · each person
/// with a gift kit), tinted by accent; tapping narrows the timeline + stats to that person.
struct HistoryFilterRow: View {
    let facets: [HistoryRecipientFacet]
    let selected: HistoryRecipientFilter
    let onSelect: (HistoryRecipientFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CrumbMetrics.Space.s) {
                ForEach(facets) { facet in
                    let isSelected = facet.filter == selected
                    let accent = facet.accentHex.map { Color(hex: $0) } ?? CrumbColor.ink
                    Button {
                        onSelect(facet.filter)
                    } label: {
                        Text(facet.label)
                            .font(CrumbType.pill)
                            .foregroundStyle(isSelected ? .white : CrumbColor.ink)
                            .padding(.horizontal, CrumbMetrics.Space.m)
                            .padding(.vertical, CrumbMetrics.Space.s)
                            .background(
                                Group {
                                    if isSelected {
                                        Capsule().fill(accent)
                                    } else {
                                        Capsule().fill(CrumbColor.raised)
                                            .overlay(Capsule().strokeBorder(CrumbColor.line, lineWidth: 1))
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(facet.label)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("historyFilterRow")
    }
}

// MARK: - Shared helpers

private extension View {
    /// Strips a List row of its chrome (insets/background/separator) so a Crumb card floats on the
    /// paper board — the price of getting native swipe-to-delete + sections for the timeline.
    func plainHistoryRow() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: CrumbMetrics.Space.xs, leading: CrumbMetrics.Space.xl,
                bottom: CrumbMetrics.Space.xs, trailing: CrumbMetrics.Space.xl
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A subtle reveal: cards fade + rise on first appear, lightly staggered. A no-op under Reduce
/// Motion (the content simply shows). Works in the timeline List and the detail's item cascade.
struct HistoryReveal: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                guard !reduceMotion, !shown else { return }
                withAnimation(.easeOut(duration: 0.35).delay(Double(min(index, 6)) * 0.05)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Applies the Crumb reveal animation (fade + rise), staggered by `index`, honoring Reduce Motion.
    func crumbReveal(index: Int, reduceMotion: Bool) -> some View {
        modifier(HistoryReveal(index: index, reduceMotion: reduceMotion))
    }
}
