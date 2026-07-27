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
                } else {
                    // The empty landing keeps the greeting as the last element so it stays glued to
                    // the dock. With no rows to scroll there is nothing for a bottom anchor to hide.
                    greeting
                }
            }
            // Without an explicit full-width frame the ScrollView sizes to the content's intrinsic
            // width and centers it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
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

            Button {
                model.resumeThread(thread)
            } label: {
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

                    Text(callToAction)
                        .font(CrumbType.pill)
                        .foregroundStyle(CrumbColor.paper)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(CrumbColor.pine, in: Capsule())
                        .padding(.top, CrumbMetrics.Space.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(state == .stalled ? CrumbColor.ochre.opacity(0.45) : CrumbColor.line, lineWidth: 1)
        )
        // One element for VoiceOver: the whole card is one destination, and the row's own label
        // already carries the state, the reason and the age.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sectionLabel). Continue \(title), \(detail), \(when)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.resumeThread(thread) }
        .accessibilityIdentifier("homeHero")
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
