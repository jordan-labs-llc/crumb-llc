import SwiftUI
import CrumbKit
import CrumbArt

/// One chronological mission conversation. The feed is immutable scrollback; the response dock is
/// the only place a person can answer Crumb or mutate mission state.
struct MissionThreadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let thread = model.activeThread {
            MissionConversationFeed(thread: thread)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MissionResponseDock()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("MissionThreadScreen")
        } else {
            ContentUnavailableView(
                "Mission unavailable",
                systemImage: "bubble.left.and.exclamationmark.bubble.right"
            )
            .onAppear { model.goToMissions() }
        }
    }
}

private struct MissionConversationFeed: View {
    let thread: MissionThread

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isLatestVisible = true
    @State private var hasUserScrolled = false
    @State private var positionedInteractionID: String?

    private let endID = "missionFeedEnd"

    /// How far past the viewport the end marker may sit while the feed still counts as "at the
    /// latest". It has to cover everything laid out below the last turn — the stack's own bottom
    /// padding — or resting exactly at the bottom leaves the marker a hair over the line and floats a
    /// "Jump to latest" button over a card that is already fully visible.
    private let endVisibilitySlack = CrumbMetrics.Space.l + CrumbMetrics.Space.s

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                        // Bookkeeping markers (gather started, refinement requested) narrate
                        // nothing the neighboring activity receipt doesn't already say — they
                        // stay in the domain timeline but out of the conversation.
                        ForEach(thread.timeline.filter(\.isRenderedTurn)) { event in
                            MissionTurnView(event: event)
                                // `position(...)` bottom-anchors the live prompt, which lands its
                                // last line flush on the dock seam — the question was reading as
                                // clipped mid-letterform under the divider. The gap has to belong to
                                // this row: the stack's own bottom padding sits outside the anchored
                                // frame, so it can't hold the seam open.
                                .padding(.bottom, isLivePrompt(event) ? CrumbMetrics.Space.l : 0)
                                .id(event.id)
                        }

                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: MissionFeedEndPreferenceKey.self,
                                value: geometry.frame(in: .named("missionConversationScroll")).maxY
                            )
                        }
                        .frame(height: 1)
                        .id(endID)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("missionFeedEnd")
                    }
                    .padding(.horizontal, CrumbMetrics.Space.xl)
                    .padding(.top, CrumbMetrics.Space.m)
                    .padding(.bottom, CrumbMetrics.Space.l)
                }
                .coordinateSpace(name: "missionConversationScroll")
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("missionConversationFeed")
                .onPreferenceChange(MissionFeedEndPreferenceKey.self) { endY in
                    isLatestVisible = endY <= viewport.size.height + endVisibilitySlack
                }
                .onScrollPhaseChange { _, newPhase in
                    // Programmatic positioning enters `.animating`; only direct tracking/interacting
                    // means the person chose a reading position that future turns must preserve.
                    if newPhase == .tracking || newPhase == .interacting {
                        hasUserScrolled = true
                    }
                }
                .onAppear {
                    if let interaction = thread.pendingInteraction {
                        position(
                            interactionID: interaction.id,
                            promptEventID: interaction.promptEventID,
                            using: proxy
                        )
                    } else if !voiceOverEnabled {
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(endID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: thread.pendingInteraction?.id) { _, newID in
                    guard let interaction = thread.pendingInteraction,
                          newID == interaction.id,
                          !hasUserScrolled else { return }
                    // The new prompt can contain a large product/plan attachment. Position by the
                    // frozen prompt turn itself instead of consulting the old end-anchor visibility,
                    // which may already have flipped false after layout.
                    position(
                        interactionID: interaction.id,
                        promptEventID: interaction.promptEventID,
                        using: proxy
                    )
                }
                .onChange(of: thread.timeline.last?.id) {
                    guard isLatestVisible, !voiceOverEnabled else { return }
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(endID, anchor: .bottom)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isLatestVisible {
                        Button {
                            withAnimation(.easeOut(duration: 0.22)) {
                                proxy.scrollTo(endID, anchor: .bottom)
                            }
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(CrumbType.captionStrong)
                                .foregroundStyle(CrumbColor.ink)
                                .padding(.horizontal, CrumbMetrics.Space.m)
                                .padding(.vertical, CrumbMetrics.Space.s)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(CrumbColor.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Jump to latest message")
                        .accessibilityIdentifier("missionJumpToLatest")
                        .padding(CrumbMetrics.Space.m)
                    }
                }
            }
        }
    }

    /// The turn carrying the question currently awaiting an answer — the one `position(...)` anchors.
    private func isLivePrompt(_ event: MissionThreadEvent) -> Bool {
        event.id == thread.pendingInteraction?.promptEventID
    }

    private func position(
        interactionID: String,
        promptEventID: String,
        using proxy: ScrollViewProxy
    ) {
        guard !voiceOverEnabled, positionedInteractionID != interactionID else { return }
        positionedInteractionID = interactionID
        Task { @MainActor in
            // Two layout turns are intentional: LazyVStack first realizes the prompt row, then its
            // frozen artifact reports its full height. The second position uses that final geometry.
            await Task.yield()
            proxy.scrollTo(promptEventID, anchor: .bottom)
            await Task.yield()
            proxy.scrollTo(promptEventID, anchor: .bottom)
        }
    }
}

private extension MissionThreadEvent {
    /// Domain bookkeeping markers whose visible text merely repeats the adjacent activity
    /// receipt. They remain in the persisted timeline; the conversation just doesn't read
    /// the same line twice.
    var isRenderedTurn: Bool {
        switch kind {
        case .gatheringStarted, .refinementRequested: false
        default: true
        }
    }
}

private struct MissionFeedEndPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MissionTurnView: View {
    let event: MissionThreadEvent

    var body: some View {
        Group {
            if event.kind == .userMessage {
                userTurn
            } else if isAssistantTurn {
                assistantTurn
            } else {
                statusTurn
            }
        }
        .opacity(event.isSuperseded ? 0.68 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionTurn.\(event.id)")
    }

    private var userTurn: some View {
        HStack(alignment: .top) {
            Spacer(minLength: CrumbMetrics.Space.xl)
            Text(event.text)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CrumbMetrics.Space.m)
                .padding(.vertical, CrumbMetrics.Space.s)
                .background(
                    CrumbColor.pineSoft,
                    in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                )
                .accessibilityLabel("You: \(event.text)")
                .accessibilityIdentifier("missionTurnText.\(event.id)")
        }
    }

    private var assistantTurn: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            CrumbBadge(size: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
                // A rich proposal is the object Crumb is asking about. Put its question after the
                // frozen artifact so bottom-aligning the pending turn reveals both the latest facts
                // and the actual prompt, matching conversational reading order.
                if placesQuestionAfterArtifacts {
                    artifactBlocks
                    assistantText
                } else {
                    assistantText
                    artifactBlocks
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var assistantText: some View {
        if !event.text.isEmpty {
            Text(event.text)
                .font(CrumbType.curatorCaption)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Crumb: \(event.text)")
                .accessibilityIdentifier("missionTurnText.\(event.id)")
        }
    }

    private var artifactBlocks: some View {
        ForEach(Array(event.blocks.enumerated()), id: \.offset) { _, block in
            MissionArtifactView(block: block, isSuperseded: event.isSuperseded)
        }
    }

    private var placesQuestionAfterArtifacts: Bool {
        event.blocks.contains { block in
            switch block {
            case .plan, .product, .comparison, .kit: true
            case .text, .activity: false
            }
        }
    }

    private var statusTurn: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(event.kind == .failure ? CrumbColor.ochre : CrumbColor.ink3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                Text(event.text)
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("missionTurnText.\(event.id)")
                ForEach(Array(event.blocks.enumerated()), id: \.offset) { _, block in
                    MissionArtifactView(block: block, isSuperseded: event.isSuperseded)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel(event.text + (event.isSuperseded ? ", superseded" : ""))
    }

    private var isAssistantTurn: Bool {
        event.kind == .assistantMessage || event.kind == .planReady || !event.blocks.isEmpty
    }

    private var statusIcon: String {
        switch event.kind {
        case .userMessage, .refinementRequested: "person.fill"
        case .assistantMessage: "sparkles"
        case .planningStarted, .gatheringStarted: "ellipsis"
        case .planReady, .gatheringCompleted, .refinementApplied: "checkmark.circle.fill"
        case .productsFound: "magnifyingglass.circle.fill"
        case .refinementsReset: "arrow.counterclockwise"
        case .productAdded: "plus.circle.fill"
        case .productSkipped: "xmark.circle"
        case .productRemoved: "minus.circle"
        case .variantChanged: "slider.horizontal.3"
        case .cartOpened: "bag.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .interrupted: "pause.circle.fill"
        case .notice: "info.circle"
        }
    }
}

private struct MissionArtifactView: View {
    let block: MissionMessageBlock
    let isSuperseded: Bool

    @ViewBuilder
    var body: some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .plan(let snapshot):
            MissionPlanSnapshotView(snapshot: snapshot, isSuperseded: isSuperseded)
        case .product(let snapshot):
            MissionProductSnapshotView(snapshot: snapshot)
        case .comparison(let snapshot):
            MissionComparisonSnapshotView(snapshot: snapshot)
        case .kit(let snapshot):
            MissionKitSnapshotView(snapshot: snapshot)
        case .activity(let receipt):
            MissionActivityArtifact(receipt: receipt, isSettled: isSuperseded)
        }
    }
}

private struct MissionActivityArtifact: View {
    let receipt: MissionActivityReceipt
    var isSettled = false

    var body: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.m) {
            // Live work spins; a resolved working turn reads as finished history, never as a
            // spinner running forever in scrollback.
            if isSettled {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(CrumbColor.ink3)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
                Text(receipt.title)
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                if let detail = receipt.detail, !detail.isEmpty {
                    Text(detail)
                        .font(CrumbType.callout)
                        .foregroundStyle(CrumbColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.pineSoft, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("missionArtifact.activity.\(receipt.id)")
    }
}

private struct MissionKitSnapshotView: View {
    let snapshot: MissionKitSnapshot

    private var subtotal: Decimal {
        snapshot.items.reduce(0) { $0 + $1.presentedPrice }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack {
                Label(snapshot.items.isEmpty ? "No picks yet" : "What you kept", systemImage: "bag")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.pine)
                Spacer(minLength: CrumbMetrics.Space.s)
                if !snapshot.items.isEmpty {
                    Text(subtotal, format: .currency(code: "USD"))
                        .font(CrumbType.headline)
                        .monospacedDigit()
                }
            }

            if snapshot.items.isEmpty {
                Text("There isn’t anything in this kit yet.")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
            } else {
                ForEach(snapshot.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title)
                                .font(CrumbType.body)
                                .foregroundStyle(CrumbColor.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: CrumbMetrics.Space.s)
                            Text(item.presentedPrice, format: .currency(code: "USD"))
                                .font(CrumbType.captionStrong)
                                .monospacedDigit()
                        }
                        Text("\(item.variantTitle) · \(item.merchant)")
                            .font(CrumbType.caption)
                            .foregroundStyle(CrumbColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if item.id != snapshot.items.last?.id { Divider() }
                }
            }
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionArtifact.kit.\(snapshot.id)")
    }
}
