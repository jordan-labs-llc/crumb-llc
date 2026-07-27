import SwiftUI
import CrumbKit
import CrumbArt

/// The conversation landing page: one deliverable, then who owes the next move.
///
/// Home has two distinct compositions rather than one list that degrades:
///
/// **Empty** — the ask at full height, resting on the dock. The greeting sits adjacent to the field it
/// explains, and the dock carries the recipient control and your recent goals, so the screen has
/// substance instead of reading as a fetch that failed.
///
/// **Populated** — top-anchored and newest-first. The most recently touched mission gets the hero slot
/// and renders whatever it *has* (a kit to review, a stall to decide, a gather in flight); everything
/// below it splits into what is waiting on you and what is waiting on Crumb. The dock collapses to one
/// line, because with work on screen the standing invitation no longer needs a headline.
///
/// This deliberately reverses the bottom-anchored, oldest-first order pinned by
/// `MissionsHomeOrderUITests`. That anchor bought proximity between the question and the field and paid
/// for it with a half-empty screen and a scan order that met the stalest mission first.
struct MissionsView: View {
    @Environment(AppModel.self) private var model

    /// The clock Home's relative stamps are read against.
    ///
    /// These used to be computed as `relativeTime(thread.updatedAt, now: Date())` inside a view's
    /// computed property, with nothing to invalidate it — so a mission stayed "Just now" for as long
    /// as no *other* state changed. Observed live: three missions started 08:34–08:36 still read
    /// "Just now" at 08:39, and only jumped to "3m/4m ago" when an unrelated kit write forced a
    /// redraw. That is the one thing the stamp exists to rule out ("four seconds or four weeks"), so
    /// it gets a real clock rather than an accident of redraw timing.
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                if !model.threadLoadFailures.isEmpty {
                    ThreadRecoverySection(failures: model.threadLoadFailures)
                }
                if let hero = model.incompleteThreads.first {
                    HomeHeroCard(thread: hero, now: now)
                    HomeMissionSections(threads: Array(model.incompleteThreads.dropFirst()), now: now)
                    // One or two missions leave most of the screen empty: the column is top-anchored,
                    // the dock has collapsed to a line, and nothing auto-focuses (the dock only claims
                    // the keyboard on an EMPTY Home), so the space just sits there. A spacer that can
                    // only expand when the list is short pushes a short-form ask to the floor, and
                    // collapses to nothing once the missions fill the viewport — so there is no count
                    // threshold and no second layout to keep in step with this one.
                    Spacer(minLength: 0)
                    followUpAsk
                } else {
                    // The empty landing keeps the greeting as the last element so it stays glued to
                    // the dock, which auto-focuses here — the question ends up directly above the
                    // keyboard rather than stranded above a gap.
                    greeting
                }
            }
            // Without an explicit full-width frame the ScrollView sizes to the content's intrinsic
            // width and centers it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
            // Give the column at least a viewport of height so the spacer above has something to
            // expand into. Without this the VStack is only as tall as its rows and the spacer is
            // always zero, which is the bug this fixes.
            .containerRelativeFrame(.vertical, alignment: .top) { height, _ in height }
        }
        // Anchoring flips with the composition: the empty ask rests on the dock (and rides up with the
        // keyboard rather than re-centering), while a populated Home reads from the top so the hero is
        // the first thing seen and it is the OLDEST missions that fall off the bottom.
        .defaultScrollAnchor(hasMissions ? .top : .bottom)
        .accessibilityIdentifier("MissionsScreen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MissionResponseDock(mode: .newMission)
        }
        // A minute is the resolution of the coarsest bucket `relativeTime` can move through
        // ("Just now" → "1m ago"), so it is also the slowest tick that can keep every stamp honest.
        // The task is cancelled with the screen, so an unmounted Home costs nothing.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
    }

    private var hasMissions: Bool { !model.incompleteThreads.isEmpty }

    /// The standing invitation in short form, for a Home that already has work on it.
    ///
    /// Deliberately not the `greeting`: no display type, no teaching line, and none of the dock
    /// furniture the collapse retires. It restores the invitation to a screen that has room for it
    /// without re-opening the argument the collapse settled.
    private var followUpAsk: some View {
        Text("What else are we shopping for?")
            .font(CrumbType.title2)
            .foregroundStyle(CrumbColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, CrumbMetrics.Space.s)
            .accessibilityIdentifier("homeFollowUpAsk")
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text("What are we shopping for?")
                .font(CrumbType.display)
                .foregroundStyle(CrumbColor.ink)
            // The teaching line retires once it has been taught.
            if model.historyEntries.isEmpty {
                Text("I'll search the shops and bring back picks worth keeping.")
                    .font(CrumbType.curator)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, CrumbMetrics.Space.s)
    }
}

// MARK: - Hero

/// The most recently touched mission, rendered by what it actually holds.
///
/// One rule with no special-casing on phase: the hero is always `incompleteThreads.first`. The
/// alternative — always hero the *good* news — means the screen can hide a stall behind a kit, and a
/// stall is the thing that stops all progress. The accepted cost is that Home can open on bad news.
private struct HomeHeroCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let thread: MissionThread
    let now: Date

    @State private var pendingEnd: MissionInteractionOption?

    private var state: MissionHomeState { MissionHomeStatus.state(for: thread) }
    private var title: String { thread.task?.title ?? thread.goal }
    private var detail: String { MissionHomeStatus.detail(for: thread) }
    private var when: String { MissionHomeStatus.relativeTime(thread.updatedAt, now: now) }

    /// One noun per state, and the same noun the sections below use.
    ///
    /// The hero used to say "Ready for you" directly above a section headed "Waiting on you" — two
    /// registers for one bucket, with nothing on screen explaining why the top card was a different
    /// kind of thing. Both mean *your move*, so both say so.
    private var sectionLabel: String {
        switch state {
        case .ready: return "Waiting on you"
        case .stalled: return "Needs a decision"
        case .working: return "Crumb is working"
        }
    }

    private var callToAction: String {
        switch state {
        case .ready: return thread.kit.isEmpty ? "Review the picks" : "Review the kit"
        case .stalled: return "Pick up where it stopped"
        case .working: return "Watch it work"
        }
    }

    /// The hero's own frozen question, when Home can actually finish answering it — together with the
    /// product it is about. The rules live in `MissionHomeInbox` so they are unit-tested rather than
    /// re-derived here.
    private var decision: MissionHomeDecision? { MissionHomeInbox.decision(for: thread) }

    /// Whether the options are a keep/discard pair (so they can be weighted) or a set of peers (so
    /// they must not be).
    ///
    /// A product decision is `[Add, Skip, Show another, …]` — one action, one dismissal, and some
    /// alternatives, which is exactly what a weighted pair plus a demoted row describes. A
    /// clarification's four options are equal choices, and giving one of them a filled capsule would
    /// be inventing a recommendation Crumb never made.
    private var weightsFirstOption: Bool { decision?.product != nil }

    /// The frozen question's options, weighted when they are a keep/discard pair.
    ///
    /// Three equal full-width capsules used to take ~35% of the card and ~17% of the screen, with two
    /// of the three meaning "not now". A product decision now reads as one action and one dismissal
    /// side by side, with the alternatives demoted to a text row — which is also where the route back
    /// into the mission goes, so answering from Home never hides the way in.
    @ViewBuilder
    private func answerControls(for decision: MissionHomeDecision) -> some View {
        // The interaction contract caps a question at four options; `prefix` makes that a layout
        // guarantee here rather than a promise made elsewhere.
        // A destructive option is never a capsule and never a link in the demoted row: ending a
        // mission from Home without opening it needs the same demotion and the same confirmation the
        // dock gives it (#114). It keeps its own row below everything else.
        let interaction = decision.interaction
        let choices = answerChoices(interaction)
        let enders = answerEnders(interaction)

        // At an accessibility size two capsules cannot share a row without clipping their labels, so
        // the pair unstacks — the same concession the dock makes when it routes its options into a
        // disclosure. Weighting is a nicety; a readable label is not.
        let paired = weightsFirstOption && choices.count >= 2 && !dynamicTypeSize.isAccessibilitySize
        let promoted = paired ? Array(choices.prefix(2)) : choices
        let demoted = paired ? Array(choices.dropFirst(2)) : []

        VStack(spacing: CrumbMetrics.Space.xs) {
            if paired {
                HStack(spacing: CrumbMetrics.Space.xs) {
                    ForEach(Array(promoted.enumerated()), id: \.element.id) { index, option in
                        optionButton(option, filled: index == 0)
                    }
                }
            } else {
                ForEach(Array(promoted.enumerated()), id: \.element.id) { index, option in
                    optionButton(option, filled: index == 0)
                }
            }

            // Everything the card no longer gives a capsule to, plus the mission itself. The card
            // body is still tappable, but an unlabelled tap target is not an affordance — with the
            // CTA replaced by answer buttons, this row is the only *visible* way in.
            //
            // A refinement follow-up can push this to three links ("Show another · Save to my taste ·
            // Open the mission"), which does not fit one line at any generous type size. `ViewThatFits`
            // decides that by measurement rather than by a size threshold that would be wrong for some
            // label lengths either way.
            ViewThatFits(in: .horizontal) {
                demotedRow(demoted, horizontal: true)
                demotedRow(demoted, horizontal: false)
            }

            ForEach(enders) { option in
                Button { pendingEnd = option } label: {
                    Text(option.label)
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Ends this mission. Asks you to confirm first.")
                .accessibilityIdentifier("homeHeroOption.\(option.id)")
            }
        }
        .padding(.top, CrumbMetrics.Space.xs)
    }

    @ViewBuilder
    private func demotedRow(_ demoted: [MissionInteractionOption], horizontal: Bool) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(spacing: CrumbMetrics.Space.s))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))

        layout {
            ForEach(demoted, id: \.id) { option in
                Button {
                    model.answerFromHome(thread, optionID: option.id)
                } label: {
                    Text(option.label)
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.pine)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("homeHeroOption.\(option.id)")

                // The interpunct only separates things that share a line.
                if horizontal {
                    Text("·").font(CrumbType.caption).foregroundStyle(CrumbColor.ink3)
                }
            }

            Button {
                model.resumeThread(thread)
            } label: {
                Text(secondaryRoute)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.pine)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            // Deliberately NOT "Continue …": `homeHeroOpen` already carries that word, and
            // `MissionThreadUITests` resumes by taking the *first* button matching "Continue" — a
            // second one on the same card is an ambiguity waiting to bite.
            .accessibilityLabel("Open \(title)")
            .accessibilityIdentifier("homeHeroSecondaryRoute")
        }
        // Leading alignment lives here rather than in a trailing `Spacer`, which would muddy what
        // `ViewThatFits` is measuring.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Deliberately "Open the mission" even when a kit exists. The cart is reachable only from inside
    /// the mission, so a "Review the kit" label here would name a destination this button does not
    /// reach — and the kit's count and subtotal are already stated in the summary two lines above.
    private let secondaryRoute = "Open the mission"

    private func optionButton(_ option: MissionInteractionOption, filled: Bool) -> some View {
        Button {
            model.answerFromHome(thread, optionID: option.id)
        } label: {
            Text(option.label)
                .font(CrumbType.pill)
                .foregroundStyle(filled ? CrumbColor.paper : CrumbColor.pine)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if filled {
                        Capsule().fill(CrumbColor.pine)
                    } else {
                        Capsule().strokeBorder(CrumbColor.pine, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("homeHeroOption.\(option.id)")
    }

    /// The capped option list, split the way it is rendered: the things you can do, then the exit.
    private func answerChoices(_ interaction: MissionPendingInteraction) -> [MissionInteractionOption] {
        interaction.options.prefix(4).filter { !$0.isDestructive }
    }

    private func answerEnders(_ interaction: MissionPendingInteraction) -> [MissionInteractionOption] {
        interaction.options.prefix(4).filter(\.isDestructive)
    }

    /// Matches the dock's wording — the same action deserves the same sentence wherever it's taken.
    private var endMissionWarning: String {
        let kept = thread.kit.count
        guard kept > 0 else { return "This mission stops here. You haven't kept anything yet." }
        let picks = kept == 1 ? "pick" : "picks"
        return "Your \(kept) \(picks) are saved to History. This mission stops here — Crumb won't keep shopping for it."
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
            Text(title)
                .font(CrumbType.title2)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !thread.kit.isEmpty {
                HStack(spacing: CrumbMetrics.Space.xs) {
                    ForEach(thread.kit.prefix(4), id: \.id) { item in
                        ProductThumbnail(
                            product: item.product,
                            size: 44,
                            cornerRadius: 10,
                            glyphSize: 16,
                            strokeColor: CrumbColor.line,
                            strokeWidth: 1
                        )
                    }
                }
                .padding(.top, 2)
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack(spacing: CrumbMetrics.Space.xs) {
                Text(sectionLabel.uppercased())
                    .font(CrumbType.captionStrong)
                    .tracking(0.8)
                    .foregroundStyle(state == .stalled ? CrumbColor.ochre : CrumbColor.ink3)
                Text("·")
                    .foregroundStyle(CrumbColor.ink3)
                Text(when)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
            }
            .accessibilityElement(children: .combine)

            // The summary is its own tap target so the answer controls below can be real buttons.
            // Nesting them inside one card-sized Button would make only the outer one reachable.
            Button {
                model.resumeThread(thread)
            } label: {
                summary
            }
            .buttonStyle(.plain)
            // "Continue" deliberately, matching every row below: it is the word the resume affordance
            // has always announced itself with, and both automation and VoiceOver users look for it.
            // When the hero is answerable this button is the only thing carrying it, because the card
            // container stops being a single button.
            .accessibilityLabel("Continue \(title), \(detail), \(when)")
            .accessibilityIdentifier("homeHeroOpen")

            if let decision {
                // The sentence Crumb actually posted, not the resolver's internal phrasing. The old
                // card quoted `interaction.question` — "What should I do with \(product.name)?" —
                // which nobody had been asked, and which turned a merchant's marketing clause into a
                // question about the reader ("…Ceramic Heart Trinket Tray | I Love That You Are My
                // Sister?"). The prompt says "How does this one look?"; the product says the rest.
                // Still quoted: this is Crumb reported at one remove, and the quotes plus the serif
                // are what mark it as something Crumb said rather than something Home is saying.
                Text("“\(decision.prompt)”")
                    .font(CrumbType.curatorCaption)
                    .foregroundStyle(CrumbColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                // The subject of the decision. Home used to show thumbnails of what you had already
                // decided and nothing at all of the thing it was asking you to decide — in a visual
                // commerce app, the largest gap on the screen.
                if let product = decision.product {
                    HomeDecisionSubject(product: product, name: decision.productName ?? product.title)
                }

                answerControls(for: decision)
            } else {
                // No options — or a question that only takes free text — so Home cannot finish the
                // job. Offer the mission instead of controls that would dead-end.
                Button {
                    model.resumeThread(thread)
                } label: {
                    Text(callToAction)
                        .font(CrumbType.pill)
                        .foregroundStyle(CrumbColor.paper)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(CrumbColor.pine, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, CrumbMetrics.Space.xs)
                .accessibilityIdentifier("homeHeroCallToAction")
            }
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(state == .stalled ? CrumbColor.ochre.opacity(0.45) : CrumbColor.line, lineWidth: 1)
        )
        // The container's accessibility shape has to follow what the card actually offers. When the
        // hero is answerable it holds several real controls, so `.ignore` would flatten it to one
        // element and make the options unreachable by VoiceOver — the exact people most helped by
        // answering without navigating. Only the single-destination case collapses.
        .accessibilityElement(children: decision == nil ? .ignore : .contain)
        .accessibilityLabel(
            decision == nil
                ? "\(sectionLabel). Continue \(title), \(detail), \(when)"
                : "\(sectionLabel). \(title), \(detail), \(when)"
        )
        .accessibilityAddTraits(decision == nil ? [.isButton] : [])
        .accessibilityAction {
            guard decision == nil else { return }
            model.resumeThread(thread)
        }
        .accessibilityIdentifier("homeHero")
        .confirmationDialog(
            "End this mission?",
            isPresented: Binding(
                get: { pendingEnd != nil },
                set: { if !$0 { pendingEnd = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingEnd
        ) { option in
            // Deliberately not `option.label`. The retry question's destructive option is labelled
            // "Cancel", which under "End this mission?" reads as "cancel the dialog" — the exact
            // ambiguity the confirmation exists to remove. The action names the consequence.
            Button("End mission", role: .destructive) {
                model.answerFromHome(thread, optionID: option.id)
                pendingEnd = nil
            }
            .accessibilityIdentifier("missionEndConfirm")
            // No identifier: SwiftUI rebuilds the cancel action as a system element and drops it,
            // so the UI test matches this button on its label instead.
            Button("Keep shopping", role: .cancel) { pendingEnd = nil }
        } message: { _ in
            Text(endMissionWarning)
        }
    }
}

/// The product a Home decision is about: its photo, its price, its shop, and Crumb's one line on it.
///
/// This is the smallest honest version of `MissionProductSnapshotView` — same snapshot, same fields,
/// laid out to sit inside a Home card rather than to fill a conversation. It is deliberately *not*
/// tappable: the two capsules below it are the decision, and a third destination here would just
/// compete with them.
private struct HomeDecisionSubject: View {
    let product: MissionProductSnapshot
    /// The merchant title with its merchandising clauses removed.
    let name: String

    var body: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.m) {
            art
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                        .strokeBorder(CrumbColor.line, lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(product.presentedPrice.formatted(.currency(code: "USD"))) · \(product.merchant)")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                    .monospacedDigit()

                if !product.rationale.isEmpty {
                    Text(product.rationale)
                        .font(CrumbType.curatorCaption)
                        .foregroundStyle(CrumbColor.ink2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, CrumbMetrics.Space.xs)
        .accessibilityElement(children: .ignore)
        // VoiceOver keeps the *raw* merchant title: the display name is a visual shortening, and a
        // person searching by what the shop calls it should still find it.
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("homeHeroSubject.\(product.productID)")
    }

    @ViewBuilder
    private var art: some View {
        if let imageURL = product.imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .empty, .failure: placeholder
                @unknown default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ProductArt(stops: [0x315F5A, 0x8AB5A8], symbol: "shippingbox.fill", seed: product.productID)
    }

    private var accessibilitySummary: String {
        var parts = [
            product.title,
            product.presentedPrice.formatted(.currency(code: "USD")),
            "from \(product.merchant)",
        ]
        if !product.rationale.isEmpty { parts.append(product.rationale) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sections

/// Everything below the hero, split by who owes the next move.
///
/// The split is the one cut that changes what a person does: `.ready` and `.stalled` are both your
/// move, `.working` is Crumb's. Empty sections don't render, headers included — a header over nothing
/// was the original argument for having no headers at all.
private struct HomeMissionSections: View {
    let threads: [MissionThread]
    let now: Date

    private var waitingOnYou: [MissionThread] {
        threads.filter { MissionHomeStatus.state(for: $0) != .working }
    }

    private var working: [MissionThread] {
        threads.filter { MissionHomeStatus.state(for: $0) == .working }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
            if !waitingOnYou.isEmpty {
                HomeMissionSection(
                    title: "Waiting on you",
                    tint: CrumbColor.ochre,
                    threads: waitingOnYou,
                    now: now,
                    identifier: "homeWaitingSection"
                )
            }
            if !working.isEmpty {
                HomeMissionSection(
                    title: "Crumb is working",
                    tint: CrumbColor.ink3,
                    threads: working,
                    now: now,
                    identifier: "homeWorkingSection"
                )
            }
        }
    }
}

private struct HomeMissionSection: View {
    let title: String
    let tint: Color
    let threads: [MissionThread]
    let now: Date
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            // The count is what "8 missions and 12 missions render the same screen" was missing:
            // depth becomes a number instead of something you infer from a clipped card.
            Text("\(title.uppercased()) · \(threads.count)")
                .font(CrumbType.captionStrong)
                .tracking(0.8)
                .foregroundStyle(tint)
                .accessibilityLabel("\(title), \(threads.count)")

            ForEach(threads, id: \.id) { thread in
                HomeMissionRow(thread: thread, now: now)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// One mission below the hero: state in form (glyph + tint), a reason, and its age.
private struct HomeMissionRow: View {
    @Environment(AppModel.self) private var model
    let thread: MissionThread
    let now: Date
    @State private var pendingDeletion: MissionThread?

    private var state: MissionHomeState { MissionHomeStatus.state(for: thread) }
    private var title: String { thread.task?.title ?? thread.goal }
    private var detail: String { MissionHomeStatus.detail(for: thread) }
    private var when: String { MissionHomeStatus.relativeTime(thread.updatedAt, now: now) }

    /// A stall no longer looks like a finished mission. This is the whole point of the glyph.
    private var glyph: String {
        switch state {
        case .ready: return "arrow.right"
        case .stalled: return "exclamationmark"
        case .working: return "ellipsis"
        }
    }

    private var glyphTint: Color { state == .stalled ? CrumbColor.ochre : CrumbColor.pine }
    private var glyphBackground: Color {
        state == .stalled ? CrumbColor.ochre.opacity(0.14) : CrumbColor.pineSoft
    }

    var body: some View {
        Button {
            model.resumeThread(thread)
        } label: {
            HStack(spacing: CrumbMetrics.Space.m) {
                ZStack {
                    Circle().fill(glyphBackground)
                    Image(systemName: glyph)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(glyphTint)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    // Reason and age on one line. Recency is the only thing the sort encodes and it
                    // used to be invisible, so "Searching shops" could mean four seconds or four weeks.
                    Text("\(detail) · \(when)")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(
                    state == .stalled ? CrumbColor.ochre.opacity(0.35) : CrumbColor.line,
                    lineWidth: 1
                )
        )
        .accessibilityLabel("Continue \(title), \(detail), \(when)")
        .accessibilityIdentifier("continueThread.\(thread.id)")
        .contextMenu {
            Button("Delete mission", role: .destructive) {
                pendingDeletion = thread
            }
            .accessibilityIdentifier("deleteThread.\(thread.id)")
        }
        .accessibilityAction(named: "Delete mission") {
            pendingDeletion = thread
        }
        .confirmationDialog(
            "Delete this mission?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { thread in
            Button("Delete mission", role: .destructive) {
                model.deleteThread(thread)
                pendingDeletion = nil
            }
            .accessibilityIdentifier("deleteThread.confirm")
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { thread in
            Text("This removes \(thread.task?.title ?? thread.goal) from this device.")
        }
    }
}

// MARK: - Recovery

/// Quarantined thread rows remain visible and deletable instead of silently disappearing.
private struct ThreadRecoverySection: View {
    @Environment(AppModel.self) private var model
    let failures: [MissionThreadLoadFailure]

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Label("Couldn’t restore", systemImage: "exclamationmark.icloud")
                .font(CrumbType.captionStrong)
                .foregroundStyle(CrumbColor.ochre)
            ForEach(failures) { failure in
                HStack(alignment: .top, spacing: CrumbMetrics.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.title)
                            .font(CrumbType.headline)
                            .foregroundStyle(CrumbColor.ink)
                        Text("This saved mission is damaged and can’t be opened.")
                            .font(CrumbType.caption)
                            .foregroundStyle(CrumbColor.ink2)
                    }
                    Spacer(minLength: 0)
                    Button("Delete", role: .destructive) {
                        model.deleteThreadLoadFailure(failure)
                    }
                    .font(CrumbType.captionStrong)
                    .accessibilityIdentifier("deleteThreadFailure.\(failure.id)")
                }
                .crumbCard()
            }
        }
        .accessibilityIdentifier("threadRecoverySection")
    }
}
