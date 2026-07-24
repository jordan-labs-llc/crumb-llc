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
                greeting
                if !model.incompleteThreads.isEmpty {
                    ContinueMissionsSection(threads: model.incompleteThreads)
                }
                if !model.threadLoadFailures.isEmpty {
                    ThreadRecoverySection(failures: model.threadLoadFailures)
                }
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
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
            Text("Hand me any goal in your own words. I'll break it into a plan and bring you a kit.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, CrumbMetrics.Space.s)
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

/// Durable, unfinished mission threads sorted by the model's recency order. Resume is the only
/// visible row action; destructive management stays available from the context menu and VoiceOver.
private struct ContinueMissionsSection: View {
    @Environment(AppModel.self) private var model
    let threads: [MissionThread]
    @State private var pendingDeletion: MissionThread?

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Label("Continue", systemImage: "bubble.left.and.bubble.right")
                .font(CrumbType.captionStrong)
                .foregroundStyle(CrumbColor.ink3)

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
                            Text(status(for: thread.phase))
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
                .accessibilityLabel("Continue \(thread.task?.title ?? thread.goal), \(status(for: thread.phase))")
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

    private func status(for phase: MissionThreadPhase) -> String {
        switch phase {
        case .planning: "Planning"
        case .planReady: "Ready to shop"
        case .gathering: "Searching shops"
        case .deckReady: "Picks ready"
        case .failed: "Needs attention"
        case .declined: "Ready for another goal"
        case .completed: "Completed"
        case .abandoned: "Ended"
        }
    }
}
