import SwiftUI
import CrumbKit

/// The mission's deliverable, pinned above the conversation.
///
/// The thread used to render the kit as a card in the middle of the feed, so the single most
/// important fact in a mission — what you are about to buy, and for how much — scrolled away and had
/// to be hunted for. This is the same move Home made one screen up: lead with the outcome, and let
/// the process sit underneath it.
///
/// It is also where the mission's *progress* lives now that the feed no longer narrates itself. The
/// meter carries ``MissionHomeState`` so "Crumb is working" reads in form as well as words — the
/// receipt lines that used to be the only evidence of background work are gone.
struct MissionKitHeader: View {
    let thread: MissionThread

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: String { thread.task?.title ?? thread.goal }
    private var state: MissionHomeState { MissionHomeStatus.state(for: thread) }
    private var kept: [KitItem] { thread.kit }

    /// How many things this mission is assembling.
    ///
    /// A single-item mission is looking for *one* thing however many queries it ran to find it, so
    /// it reports one part and the header stays quiet about counts. Reading `plan.count` alone let
    /// a shortlist mission announce "5 parts" while showing one product and its two alternatives.
    private var partCount: Int { thread.task?.isSingleItem == true ? 1 : thread.plan.count }
    private var subtotal: Decimal { kept.reduce(0) { $0 + $1.variant.price } }

    /// Only ever ≥ 2. One shop is not a fact worth a slot; two is the point at which the kit means
    /// two independent merchant orders, which is the thing UCP makes real and the cart later splits on.
    private var shopCount: Int? {
        let shops = Set(kept.map(\.product.shop.id)).count
        return shops >= 2 ? shops : nil
    }

    /// Thumbnails are the first thing to go when type grows: at accessibility sizes 44pt of art plus
    /// grown labels pushes the live decision — the only thing on screen that can be acted on — off
    /// the bottom.
    private var showsThumbnails: Bool {
        !kept.isEmpty && !dynamicTypeSize.isAccessibilitySize
    }

    /// Before anything is kept there is no deliverable to lead with, so the header states the shape of
    /// the work instead. It deliberately shows no money: a `$0.00` subtotal presented as an
    /// achievement is the empty-screen void again, one screen deeper.
    private var hasDeliverable: Bool { !kept.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: CrumbMetrics.Space.s) {
                Text(title)
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if hasDeliverable {
                    Text(subtotal, format: .currency(code: "USD"))
                        .font(CrumbType.title2)
                        .foregroundStyle(CrumbColor.ink)
                        .monospacedDigit()
                        .fixedSize()
                }
            }

            if partCount > 0 {
                CrumbProgressMeter(fraction: fraction, tint: meterTint)
            }

            HStack(spacing: CrumbMetrics.Space.s) {
                if showsThumbnails {
                    HStack(spacing: CrumbMetrics.Space.xs) {
                        ForEach(kept.prefix(4)) { item in
                            ProductThumbnail(
                                product: item.product,
                                size: 30,
                                cornerRadius: 8,
                                glyphSize: 12,
                                strokeColor: CrumbColor.line,
                                strokeWidth: 1
                            )
                        }
                    }
                    .accessibilityHidden(true)
                }

                // A planless, empty, settled mission has nothing true to say here, and an empty label
                // still claims a line.
                if !statusLine.isEmpty {
                    Text(statusLine)
                        .font(CrumbType.caption)
                        .foregroundStyle(state == .stalled ? CrumbColor.ochre : CrumbColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, CrumbMetrics.Space.l)
        .padding(.vertical, CrumbMetrics.Space.m)
        // The same glass the dock uses, and for the same reason: the feed scrolls *under* both. An
        // opaque panel sliced whatever line happened to be at the seam clean in half; through material
        // it reads as content passing beneath a surface, which is what is actually happening.
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().foregroundStyle(CrumbColor.line) }
        // One element: this is a status readout, not a place to poke. Everything actionable is in the
        // dock, which is the contract the rest of the thread already keeps.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("missionKitHeader")
    }

    /// Kept items against planned parts. Clamped because a person can keep more than one thing per
    /// part (two bags of beans), and a meter that overshoots reads as broken rather than generous.
    private var fraction: Double {
        guard partCount > 0 else { return 0 }
        return min(1, Double(kept.count) / Double(partCount))
    }

    private var meterTint: Color {
        switch state {
        case .ready: return CrumbColor.pine
        case .stalled: return CrumbColor.ochre
        case .working: return CrumbColor.ink3
        }
    }

    /// The line that replaced the receipts. `working` has to say so out loud, because deleting
    /// "Found 5 options so far." removed the only ambient signal that anything was happening.
    private var statusLine: String {
        var parts: [String] = []
        // A single-part mission says nothing about parts. "1 parts" was both ungrammatical and
        // noise — the title already names the one thing being shopped for, so counting it tells
        // nobody anything. Parts are only a fact worth a slot once there is more than one.
        if partCount > 1 {
            parts.append(hasDeliverable ? "\(kept.count) of \(partCount) kept" : "\(partCount) parts")
        } else if hasDeliverable {
            parts.append(kept.count == 1 ? "1 kept" : "\(kept.count) kept")
        }
        if let shopCount { parts.append("\(shopCount) shops") }
        switch state {
        // While the search is actually returning things, the count *replaces* the generic sentence
        // rather than joining it. A gather can run for the better part of a minute, and for all of
        // it "Crumb is working…" said the same thing at second 2 and second 40 — the pill beside the
        // spinner and the dock were already saying that much. A number that climbs is the one fact
        // this line can add, and it costs no new state: the streamed gather writes each batch into
        // the thread as it lands. Before the first batch, and while planning, it stays quiet.
        case .working: parts.append(MissionHomeStatus.workingDetail(for: thread) ?? "Crumb is working…")
        case .stalled: parts.append("Needs a decision")
        case .ready: break
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [title]
        if hasDeliverable {
            parts.append("\(kept.count) kept")
            parts.append("subtotal \(subtotal.formatted(.currency(code: "USD")))")
            if partCount > 0 { parts.append("of \(partCount) parts") }
        } else if partCount > 1 {
            parts.append("\(partCount) parts, nothing kept yet")
        } else if partCount == 1 {
            parts.append("nothing kept yet")
        }
        if let shopCount { parts.append("across \(shopCount) shops") }
        switch state {
        // Mirrors `statusLine`. The header is one ignored element with a hand-built label, so a
        // counter added only to the visible text would make the mission screen — the screen this
        // whole thing is for — the one place the progress is inaudible.
        case .working: parts.append(MissionHomeStatus.workingDetail(for: thread) ?? "Crumb is working")
        case .stalled: parts.append("needs a decision")
        case .ready: break
        }
        return parts.joined(separator: ", ")
    }
}

/// A thin capsule meter. Its own view so the zero-progress case still draws a track rather than
/// collapsing to nothing.
private struct CrumbProgressMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(CrumbColor.pineSoft)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
