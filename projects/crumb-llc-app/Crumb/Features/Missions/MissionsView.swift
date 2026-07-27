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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                if !model.threadLoadFailures.isEmpty {
                    ThreadRecoverySection(failures: model.threadLoadFailures)
                }
                if let hero = model.incompleteThreads.first {
                    HomeHeroCard(thread: hero)
                    HomeMissionSections(threads: Array(model.incompleteThreads.dropFirst()))
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
    let thread: MissionThread

    @State private var pendingEnd: MissionInteractionOption?

    private var state: MissionHomeState { MissionHomeStatus.state(for: thread) }
    private var title: String { thread.task?.title ?? thread.goal }
    private var detail: String { MissionHomeStatus.detail(for: thread) }
    private var when: String { MissionHomeStatus.relativeTime(thread.updatedAt, now: Date()) }

    private var sectionLabel: String {
        switch state {
        case .ready: return "Ready for you"
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

    /// The hero's own frozen question, when Home can actually finish answering it.
    ///
    /// Options are the requirement: a free-text-only question needs a field Home does not have, and a
    /// thread under blocking recovery must not be answered at all. In both cases the hero falls back to
    /// opening the mission rather than showing a control that dead-ends.
    private var answerableInteraction: MissionPendingInteraction? {
        guard let interaction = thread.pendingInteraction,
              thread.blockingRecovery == nil,
              !interaction.options.isEmpty else { return nil }
        return interaction
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

            if let interaction = answerableInteraction {
                // Quote the question rather than paraphrasing it: these options resolve *that* exact
                // frozen question, and answering something subtly different from what Crumb asked is
                // how a person loses trust in a one-tap control.
                Text("“\(interaction.question)”")
                    .font(CrumbType.curatorCaption)
                    .foregroundStyle(CrumbColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

                // The interaction contract caps questions at four options; `prefix` makes that a
                // layout guarantee here rather than a promise made elsewhere.
                VStack(spacing: CrumbMetrics.Space.xs) {
                    ForEach(Array(answerChoices(interaction).enumerated()), id: \.element.id) { index, option in
                        Button {
                            model.answerFromHome(thread, optionID: option.id)
                        } label: {
                            Text(option.label)
                                .font(CrumbType.pill)
                                .foregroundStyle(index == 0 ? CrumbColor.paper : CrumbColor.pine)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background {
                                    if index == 0 {
                                        Capsule().fill(CrumbColor.pine)
                                    } else {
                                        Capsule().strokeBorder(CrumbColor.pine, lineWidth: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("homeHeroOption.\(option.id)")
                    }

                    // Home can end a mission in one tap without ever opening it, so it needs the
                    // same demotion and the same confirmation the dock gives this option — a
                    // full-width pine capsule for "End mission" would be the worst version of it.
                    ForEach(answerEnders(interaction)) { option in
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
        .accessibilityElement(children: answerableInteraction == nil ? .ignore : .contain)
        .accessibilityLabel(
            answerableInteraction == nil
                ? "\(sectionLabel). Continue \(title), \(detail), \(when)"
                : "\(sectionLabel). \(title), \(detail), \(when)"
        )
        .accessibilityAddTraits(answerableInteraction == nil ? [.isButton] : [])
        .accessibilityAction {
            guard answerableInteraction == nil else { return }
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

// MARK: - Sections

/// Everything below the hero, split by who owes the next move.
///
/// The split is the one cut that changes what a person does: `.ready` and `.stalled` are both your
/// move, `.working` is Crumb's. Empty sections don't render, headers included — a header over nothing
/// was the original argument for having no headers at all.
private struct HomeMissionSections: View {
    let threads: [MissionThread]

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
                    identifier: "homeWaitingSection"
                )
            }
            if !working.isEmpty {
                HomeMissionSection(
                    title: "Crumb is working",
                    tint: CrumbColor.ink3,
                    threads: working,
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
                HomeMissionRow(thread: thread)
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
    @State private var pendingDeletion: MissionThread?

    private var state: MissionHomeState { MissionHomeStatus.state(for: thread) }
    private var title: String { thread.task?.title ?? thread.goal }
    private var detail: String { MissionHomeStatus.detail(for: thread) }
    private var when: String { MissionHomeStatus.relativeTime(thread.updatedAt, now: Date()) }

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
