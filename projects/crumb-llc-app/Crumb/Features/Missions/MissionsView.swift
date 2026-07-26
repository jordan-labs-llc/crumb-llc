import SwiftUI
import CrumbKit
import CrumbArt

/// The read-only conversation landing page. Starting a mission uses the same response dock as every
/// later turn, so the input locus never moves from a form in the feed to a composer at the bottom.
struct MissionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                if !model.threadLoadFailures.isEmpty {
                    ThreadRecoverySection(failures: model.threadLoadFailures)
                }
                if !model.incompleteThreads.isEmpty {
                    // Reversed against the model's newest-first order: in a bottom-anchored column
                    // "nearest the dock" is the priority position, so the most recently touched
                    // mission must be last. Oldest-at-top also matches the mission thread's own
                    // chronological feed, where lower means newer.
                    ContinueMissionsSection(threads: model.incompleteThreads.reversed())
                }
                // The greeting is the LAST element, not the first. Paired with the bottom anchor
                // this is what keeps the standing invitation glued to the dock: when the list grows
                // past a screenful it is the OLDEST missions that scroll off the top, never the
                // question or the mission you touched most recently.
                greeting
            }
            // Without an explicit full-width frame the ScrollView sizes to the content's intrinsic
            // width and centers it. The old two-line subhead happened to fill the column and hid
            // this; trimming that copy made the greeting drift to the middle of the screen.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        // Rest the column on the dock instead of hanging it from the header. The empty paper then
        // falls ABOVE the greeting, and the question sits ~40pt from the field that answers it
        // rather than ~700pt. Anchoring — rather than centering — is what survives the dock's
        // auto-focus: content anchored to the bottom rides up with the keyboard, where a
        // vertically centered card would have to re-center and jump.
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("MissionsScreen")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MissionResponseDock(mode: .newMission)
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text("What are we shopping for?")
                .font(CrumbType.display)
                .foregroundStyle(CrumbColor.ink)
            // The teaching line retires once it has been taught. It also drops the old opening
            // clause ("Any goal, in your own words") which the composer placeholder already says:
            // at ~700pt apart those read as two thoughts, but now that the greeting rests on the
            // dock they sit together and read as a stutter.
            if showsTeachingLine {
                Text("I'll search the shops and bring back picks worth keeping.")
                    .font(CrumbType.curator)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, CrumbMetrics.Space.s)
    }

    /// True only for someone with nothing to show for previous visits — no unfinished missions and
    /// no completed ones. Anyone else has already learned what the field wants.
    private var showsTeachingLine: Bool {
        model.incompleteThreads.isEmpty && model.historyEntries.isEmpty
    }
}

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

/// Durable, unfinished mission threads in oldest-first order, so the most recent sits nearest the
/// dock in the bottom-anchored column. Resume is the only visible row action; destructive
/// management stays available from the context menu and VoiceOver.
private struct ContinueMissionsSection: View {
    @Environment(AppModel.self) private var model
    let threads: [MissionThread]
    @State private var pendingDeletion: MissionThread?

    var body: some View {
        // No section header. In a bottom-anchored column the top of the list is the first thing to
        // scroll away, so a "Continue" label above the rows is visible at one mission and gone at
        // two — worse than not having it. Each row states its own case instead: the arrow affords
        // resumption, the status line says what is waiting, and VoiceOver still hears "Continue …"
        // from the row's own accessibility label.
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            ForEach(threads, id: \.id) { thread in
                Button {
                    model.resumeThread(thread)
                } label: {
                    HStack(spacing: CrumbMetrics.Space.m) {
                        ZStack {
                            Circle().fill(CrumbColor.pineSoft)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(CrumbColor.pine)
                        }
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.task?.title ?? thread.goal)
                                .font(CrumbType.headline)
                                .foregroundStyle(CrumbColor.ink)
                                .lineLimit(2)
                            Text(MissionContinuationSummary.text(for: thread))
                                .font(CrumbType.caption)
                                .foregroundStyle(CrumbColor.ink2)
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
                        .strokeBorder(CrumbColor.line, lineWidth: 1)
                )
                .accessibilityLabel("Continue \(thread.task?.title ?? thread.goal), \(MissionContinuationSummary.text(for: thread))")
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("continueMissionsSection")
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
