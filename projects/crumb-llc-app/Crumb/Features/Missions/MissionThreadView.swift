import SwiftUI
import CrumbKit
import CrumbArt

/// One mission, led by its deliverable.
///
/// The kit is pinned at the top, the live decision sits at the bottom of the conversation, and the
/// dock remains the only place a person can answer Crumb or mutate mission state. The feed itself is
/// still immutable scrollback — it just no longer owns the screen, and no longer narrates every
/// internal step it took to get here.
struct MissionThreadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let thread = model.activeThread {
            MissionConversationFeed(thread: thread)
                .safeAreaInset(edge: .top, spacing: 0) {
                    MissionKitHeader(thread: thread)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        // Once anything is kept there is always a way to buy it, whatever question
                        // happens to be on the table. The reported session ended on a dock offering
                        // "Find more" and "End mission" — a finished kit with no button that moved
                        // it forward, and free text as the only way out.
                        if !thread.kit.isEmpty {
                            MissionCheckoutBar(kit: thread.kit)
                        }
                        MissionResponseDock()
                    }
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
    /// Which settled picks the person has re-opened, held here rather than in the row.
    ///
    /// `LazyVStack` discards off-screen rows, so per-row `@State` would silently re-collapse a pick the
    /// moment it scrolled out of view — exactly when someone is scrolling up to compare two of them.
    @State private var expandedPicks: Set<String> = []
    /// Folded by default: a mission screen leads with the decision, not the record of how it got
    /// here. Opt-in because the record is exactly what someone about to authorize a multi-merchant
    /// charge may want to audit.
    @State private var isHistoryExpanded = false

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
                        // Everything already decided folds into one line, so the screen is the
                        // decision in front of you rather than the log of how you got here. The
                        // reported session was five collapsed pick rows and no live card at all —
                        // a transcript of work, with the actual question pushed off the bottom.
                        if !settledHistory.isEmpty {
                            MissionHistoryDisclosure(
                                count: settledHistory.count,
                                isExpanded: isHistoryExpanded,
                                onToggle: { withAnimation(.easeOut(duration: 0.2)) { isHistoryExpanded.toggle() } }
                            )
                            if isHistoryExpanded {
                                ForEach(settledHistory) { event in
                                    MissionTurnView(
                                        event: event,
                                        isSettledPick: true,
                                        decision: decision(for: event),
                                        isExpanded: expandedPicks.contains(event.id),
                                        onToggleExpansion: { toggleExpansion(of: event) }
                                    )
                                    .id(event.id)
                                }
                            }
                        }

                        // Bookkeeping never reaches the conversation: it stays in the domain
                        // timeline (and in History) but the screen no longer reads a line for every
                        // internal step. See `isRenderedTurn`.
                        ForEach(liveTurns) { event in
                            MissionTurnView(
                                event: event,
                                isSettledPick: !isLivePrompt(event),
                                decision: decision(for: event),
                                decidedByCrumb: decidedByCrumb(event),
                                isExpanded: expandedPicks.contains(event.id),
                                onToggleExpansion: { toggleExpansion(of: event) }
                            )
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

    /// The already-decided picks, folded away by default.
    ///
    /// **Only picks fold.** A five-part kit's settled cards were what buried the live decision, and
    /// they are the one kind of turn whose content is fully restated elsewhere — the header carries
    /// the count and subtotal, the cart carries the lines. Everything else stays on screen:
    /// notices, failures, interruptions and Crumb's replies are things a person could not have
    /// worked out for themselves, and several have no other trace at all. Folding them away made
    /// Crumb answer "under $50" mid-search by appearing to say nothing.
    ///
    /// Empty while a mission has no question on the table (it is finished, or failed), because then
    /// the record *is* the content and hiding it would leave a blank screen.
    private var settledHistory: [MissionThreadEvent] {
        guard thread.pendingInteraction != nil,
              let liveIndex = renderedTimeline.firstIndex(where: isLivePrompt) else { return [] }
        return renderedTimeline[..<liveIndex].filter { $0.proposedProduct != nil }
    }

    /// Everything the screen shows inline: the live question, and every settled turn that is not a
    /// pick. Order is preserved; only the picks are lifted out into the disclosure.
    private var liveTurns: [MissionThreadEvent] {
        guard thread.pendingInteraction != nil,
              renderedTimeline.contains(where: isLivePrompt) else { return renderedTimeline }
        let folded = Set(settledHistory.map(\.id))
        return renderedTimeline.filter { !folded.contains($0.id) }
    }

    /// The turns the conversation actually reads.
    private var renderedTimeline: [MissionThreadEvent] {
        thread.timeline.filter { event in
            guard event.isRenderedTurn else { return false }
            // A working pill is a live status, not a record. Once it is no longer the question on the
            // table, its settled checkmark is process residue — and the pinned header's own pulse has
            // taken over the job of saying Crumb is busy.
            if event.isWorkingPill { return isLivePrompt(event) }
            // "Planning this mission…" is the same kind of thing and was being treated as a record:
            // it renders with a live ellipsis and never resolves, so a UXR capture found it still
            // claiming to be planning at the end of a finished mission, under the picks it had
            // already brought back. It reads only while planning is genuinely the operation in
            // flight; `loadCandidates` replaces the planning receipt with the gathering one, which
            // retires this line at exactly the moment the search takes over.
            if event.kind == .planningStarted { return isPlanningNow }
            return true
        }
    }

    private var isPlanningNow: Bool { MissionPlanningTurn.isLive(in: thread) }

    /// The turn carrying the question currently awaiting an answer — the one `position(...)` anchors.
    private func isLivePrompt(_ event: MissionThreadEvent) -> Bool {
        event.id == thread.pendingInteraction?.promptEventID
    }

    private func toggleExpansion(of event: MissionThreadEvent) {
        if expandedPicks.contains(event.id) {
            expandedPicks.remove(event.id)
        } else {
            expandedPicks.insert(event.id)
        }
    }

    /// What was decided about this turn's product, if it carries one. Drives the collapsed row's
    /// glyph, so a settled pick reads as kept or passed rather than merely old.
    private func decision(for event: MissionThreadEvent) -> MissionProductDecision.Kind? {
        guard let productID = event.productID else { return nil }
        return thread.decisions.last { $0.productID == productID }?.kind
    }

    /// Whether the decision on this turn's product was Crumb's rather than the person's. Read off
    /// the decision record, never inferred from the timeline: once delegation exists, a kit
    /// assembled automatically and one assembled a tap at a time are otherwise identical.
    private func decidedByCrumb(_ event: MissionThreadEvent) -> Bool {
        guard let productID = event.productID else { return false }
        return thread.decisions.last { $0.productID == productID }?.wasDecidedByCrumb == true
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
    /// Whether this event is part of the conversation, or merely part of the record.
    ///
    /// A five-part kit used to accumulate around fifteen permanent receipt lines — "Found 2 options so
    /// far.", "Found 5 options so far.", "5 picks ready to explore.", "Added Tabletop Burr Grinder." —
    /// one per internal step, none of them expiring. That is the run-log console Crumb decided not to
    /// inherit; it arrived anyway, one receipt at a time.
    ///
    /// So the screen now reports outcomes, not process. Everything a person could not have worked out
    /// for themselves still renders: what Crumb said, what they said, the picks, and — crucially —
    /// every failure, interruption and notice. What goes is the narration of work whose result is
    /// already on screen. On a clean run this leaves nothing behind at all, which is the honest
    /// version of a progress log for an agent that can simply show you the progress: the pinned
    /// ``MissionKitHeader`` carries the count, the subtotal and the "Crumb is working…" pulse.
    ///
    /// Nothing is deleted — the full timeline stays persisted and reaches History untouched.
    /// The test that separates the two: *did anyone ask?* Unsolicited narration of work whose result
    /// is already on screen goes. A reply to something the person did — especially something they
    /// typed in their own words — stays, even when it is technically a receipt. A conversation that
    /// silently swallows the answer to "make it cheaper" reads as one that ignored you.
    var isRenderedTurn: Bool {
        switch kind {
        case .gatheringStarted, .refinementRequested,
             .productsFound, .gatheringCompleted,
             .productAdded, .productSkipped, .productRemoved,
             .variantChanged, .cartOpened:
            return false
        // Both are Crumb answering a request, not narrating itself. `refinementApplied` reports the
        // *scope* of a rework ("I updated the remaining picks"), which a single new card does not
        // convey, and `refinementsReset` announces a state change — the deck returning to baseline —
        // that has no other visible trace at all.
        case .refinementApplied, .refinementsReset:
            return true
        // Tapping "Add" wrote a bubble reading "Add" — Crumb's own chip label, quoted back at the
        // person who just pressed it — and the pick directly above it now says "Kept" in its own
        // right. Five picks meant five such echoes, each costing a full row. A choice is legible from
        // its consequence; typed prose is the one thing in a thread nothing else preserves, so that
        // always renders.
        case .userMessage:
            return chosenOptionID == nil
        case .assistantMessage, .planningStarted, .planReady,
             .failure, .interrupted, .notice:
            return true
        }
    }

    /// A working turn: no prose of its own, just an activity pill. Live it is the question on the
    /// table ("Toss in tweaks while I search…"); settled it is a checkmark narrating finished work,
    /// which is the header's job now.
    var isWorkingPill: Bool {
        guard text.isEmpty, blocks.count == 1, case .activity = blocks[0] else { return false }
        return true
    }

    /// The single frozen product this turn proposes, if that is what it is. Comparison and kit
    /// artifacts are deliberately excluded: they are summaries already, and there are never many.
    var proposedProduct: MissionProductSnapshot? {
        guard blocks.count(where: { if case .product = $0 { true } else { false } }) == 1 else { return nil }
        for block in blocks {
            if case .product(let snapshot) = block { return snapshot }
        }
        return nil
    }
}

/// The standing way out of a mission that has something in it.
///
/// Deliberately not a chip in the dock: dock options belong to whatever question is currently
/// being asked and change as it changes, which is precisely how a kit ends up with nowhere to go.
/// This is a property of the *kit*, so it persists across every question.
private struct MissionCheckoutBar: View {
    @Environment(AppModel.self) private var model
    let kit: [KitItem]

    private var subtotal: Decimal { kit.reduce(0) { $0 + $1.variant.price } }
    private var shopCount: Int { Set(kit.map(\.product.shop.id)).count }

    /// Multi-shop is a fact worth stating before someone taps: UCP makes each merchant its own
    /// order, so "check out" here is more than one transaction and should not be a surprise.
    private var detail: String {
        let items = kit.count == 1 ? "1 item" : "\(kit.count) items"
        return shopCount >= 2 ? "\(items) · \(shopCount) shops" : items
    }

    var body: some View {
        Button {
            model.openCart()
            Task { @MainActor in await model.startCheckoutWorkflow() }
        } label: {
            HStack(spacing: CrumbMetrics.Space.m) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Check out")
                        .font(CrumbType.headline)
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(CrumbType.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: CrumbMetrics.Space.s)
                Text(subtotal, format: .currency(code: "USD"))
                    .font(CrumbType.title2)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, CrumbMetrics.Space.l)
            .padding(.vertical, CrumbMetrics.Space.m)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CrumbMetrics.Space.l)
        .padding(.bottom, CrumbMetrics.Space.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Check out, \(detail), \(subtotal.formatted(.currency(code: "USD")))")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("missionCheckoutBar")
    }
}

/// The one line that stands in for everything already decided.
///
/// Named for what it contains rather than styled as a section header: a person opens this to answer
/// "why did Crumb pick that", which is a question about work, not about chronology.
private struct MissionHistoryDisclosure: View {
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    private var label: String {
        isExpanded ? "Hide what Crumb did" : "What Crumb did"
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: CrumbMetrics.Space.s) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(CrumbColor.ink3)
                    .accessibilityHidden(true)
                Text(label)
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink2)
                if !isExpanded {
                    Text("\(count)")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide what Crumb did" : "What Crumb did, \(count) steps")
        .accessibilityHint(isExpanded ? "Folds the earlier steps away" : "Shows the earlier steps")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("missionHistoryDisclosure")
    }
}

/// Whether the "Planning this mission…" turn is still telling the truth.
///
/// It renders with a live ellipsis and no completion state, so treating it as a permanent record
/// leaves a finished mission claiming to be planning: a UXR capture found it still saying so at the
/// end of a settled mission, sitting directly above the five picks it had already brought back. It is
/// a live status like the working pill, not a receipt.
///
/// Read off the thread's own pending operation rather than `AppModel.isPlanning`, so scrollback stays
/// a pure function of the thread. `loadCandidates` swaps the planning receipt for the gathering one,
/// which retires this line at exactly the moment the search takes over. Internal so the rule is
/// unit-tested rather than living as a comparison inside a private view body.
enum MissionPlanningTurn {
    static func isLive(in thread: MissionThread) -> Bool {
        thread.pendingOperation?.retry.kind == .planning
    }
}

private struct MissionFeedEndPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MissionTurnView: View {
    let event: MissionThreadEvent
    /// True for every turn except the one currently being asked about.
    var isSettledPick = false
    /// What was decided about this turn's product, when it carries one.
    var decision: MissionProductDecision.Kind?
    /// Whether Crumb made that decision itself.
    var decidedByCrumb = false
    /// Owned by the feed, so scrolling a re-opened pick out of view doesn't fold it back up.
    var isExpanded = false
    var onToggleExpansion: () -> Void = {}

    /// A pick you have already answered collapses to the two facts that still matter — what, and how
    /// much. Its full card cost around 450pt of art and five lines of rationale, and a five-part kit
    /// left three-plus screens of settled history between a person and the live question.
    ///
    /// It collapses rather than disappears, and re-expands in place, because the rationale is the
    /// record of *why* Crumb chose this — which is exactly what someone about to authorize a
    /// multi-merchant charge may want to re-read. Per-item and opt-in, so Crumb's voice survives
    /// without being charged to everyone's scroll.
    private var collapsesPick: Bool {
        isSettledPick && !isExpanded && event.proposedProduct != nil
    }

    var body: some View {
        Group {
            if collapsesPick, let snapshot = event.proposedProduct {
                MissionSettledPickRow(
                    snapshot: snapshot, decision: decision,
                    decidedByCrumb: decidedByCrumb, onExpand: onToggleExpansion
                )
            } else if event.kind == .userMessage {
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
                    collapseControl
                } else {
                    assistantText
                    artifactBlocks
                    collapseControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The way back out of a re-expanded pick. Only a settled one can be folded up again — the live
    /// proposal is the thing being asked about and always stays open.
    @ViewBuilder
    private var collapseControl: some View {
        if isSettledPick, isExpanded, event.proposedProduct != nil {
            Button(action: onToggleExpansion) {
                Label("Show less", systemImage: "chevron.up")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("missionCollapsePick.\(event.id)")
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
            MissionArtifactView(
                block: block,
                isSuperseded: event.isSuperseded,
                isExpanded: isExpanded,
                onToggleExpansion: onToggleExpansion
            )
        }
    }

    private var placesQuestionAfterArtifacts: Bool {
        event.blocks.contains { block in
            switch block {
            case .plan, .product, .comparison, .kit: true
            // A receipt turn carries no question of its own — the question follows in its own turn —
            // so there is no reading order to reverse here.
            case .text, .activity, .autoKeep: false
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

/// A pick you have already answered, folded down to what, how much, and which way you went.
///
/// Deliberately not a card: it is a line in a ledger, and it should not compete with the one live
/// proposal on screen. Tapping it restores the full frozen card including Crumb's rationale.
private struct MissionSettledPickRow: View {
    let snapshot: MissionProductSnapshot
    let decision: MissionProductDecision.Kind?
    var decidedByCrumb = false
    let onExpand: () -> Void

    private var glyph: String {
        switch decision {
        // The same bolt the auto receipt wears. A row Crumb decided and a row you decided are both
        // "kept", and the checkmark alone said so identically — the tie back to the receipt is what
        // makes the distinction readable without spending a line of text on it.
        case .added where decidedByCrumb: return "bolt.fill"
        case .added: return "checkmark"
        case .skipped: return "arrow.uturn.forward"
        case .removed: return "minus"
        case .variantChanged: return "slider.horizontal.3"
        case nil: return "circle.dotted"
        }
    }

    /// Only a kept item earns the pine tint. A pass reads as neutral — it is not a failure, and
    /// tinting it would make a browsed-and-declined product look like a problem.
    private var isKept: Bool { decision == .added || decision == .variantChanged }

    /// "Kept" and "Kept by Crumb" are different facts about the same row, and only one of them is
    /// something the person is on the hook for having chosen.
    private var decisionWord: String {
        switch decision {
        case .added: return decidedByCrumb ? "Kept by Crumb" : "Kept"
        case .skipped: return "Passed"
        case .removed: return "Removed"
        case .variantChanged: return "Kept, changed"
        case nil: return "Seen"
        }
    }

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: CrumbMetrics.Space.m) {
                ZStack {
                    Circle().fill(isKept ? CrumbColor.pineSoft : CrumbColor.line)
                    Image(systemName: glyph)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isKept ? CrumbColor.pine : CrumbColor.ink3)
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.title)
                        .font(CrumbType.callout)
                        .foregroundStyle(isKept ? CrumbColor.ink : CrumbColor.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(snapshot.merchant)
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .lineLimit(1)
                }

                Spacer(minLength: CrumbMetrics.Space.s)

                Text(snapshot.presentedPrice, format: .currency(code: "USD"))
                    .font(CrumbType.caption)
                    .foregroundStyle(isKept ? CrumbColor.ink : CrumbColor.ink3)
                    .monospacedDigit()
                    .fixedSize()

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CrumbColor.ink3)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(decisionWord): \(snapshot.title), \(snapshot.presentedPrice.formatted(.currency(code: "USD"))), from \(snapshot.merchant)"
        )
        .accessibilityHint("Shows the full pick and why Crumb chose it")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("missionSettledPick.\(snapshot.productID)")
    }
}

private struct MissionArtifactView: View {
    let block: MissionMessageBlock
    let isSuperseded: Bool
    /// Shared with the settled-pick collapse: both are "this turn is folded up", and a turn is
    /// never both at once.
    var isExpanded = false
    var onToggleExpansion: () -> Void = {}

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
        // The kit artifact is not drawn any more. It used to be a full itemised card mid-feed, which
        // is now the third copy of the same list: the pinned header states the count and the
        // subtotal, every pick is already a row in the scrollback with its own verdict and price, and
        // "Review cart" opens the real itemised cart one tap away. The block stays in the timeline —
        // `MissionThread` validates the kit interaction against it — it simply isn't read aloud twice.
        case .kit:
            EmptyView()
        case .activity(let receipt):
            MissionActivityArtifact(receipt: receipt, isSettled: isSuperseded)
        case .autoKeep(let snapshot):
            MissionAutoKeepArtifact(
                snapshot: snapshot, isReversed: isSuperseded,
                isExpanded: isExpanded, onToggle: onToggleExpansion
            )
        }
    }
}

/// What Crumb kept while you weren't answering, folded into one line.
///
/// This is the one piece of narration the mission screen reintroduces, and it earns the space on a
/// rule the deleted receipts failed: those described work whose *result was already on screen*, so
/// reading them told you nothing new. These are decisions nobody watched being made. Collapsed it is
/// a single row; open it is a ledger in the settled picks' own visual language; and when auto refused
/// something, the refusal is stated in ochre rather than left to be discovered in the deck.
private struct MissionAutoKeepArtifact: View {
    let snapshot: MissionAutoKeepSnapshot
    /// The person took the undo. The row stays — it happened — but it must stop reading as a
    /// statement about what is in the kit right now.
    var isReversed = false
    let isExpanded: Bool
    let onToggle: () -> Void

    private var headline: String {
        let kept = snapshot.kept.count == 1
            ? "Kept 1 pick on my own"
            : "Kept \(snapshot.kept.count) picks on my own"
        return isReversed ? "\(kept) — undone" : kept
    }

    private var subtotal: Decimal { snapshot.kept.reduce(0) { $0 + $1.presentedPrice } }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Button(action: onToggle) {
                HStack(spacing: CrumbMetrics.Space.s) {
                    Image(systemName: "bolt.badge.clock")
                        .font(.subheadline)
                        .foregroundStyle(CrumbColor.pine)
                        .accessibilityHidden(true)
                    Text(headline)
                        .font(CrumbType.captionStrong)
                        .foregroundStyle(CrumbColor.ink)
                    Spacer(minLength: CrumbMetrics.Space.xs)
                    Text(subtotal, format: .currency(code: "USD"))
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink2)
                        .monospacedDigit()
                        .fixedSize()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CrumbColor.ink3)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(headline), \(subtotal.formatted(.currency(code: "USD"))) in total"
            )
            .accessibilityHint("Shows what Crumb kept and why")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("missionAutoKeepReceipt.\(snapshot.id)")

            if isExpanded {
                ForEach(snapshot.kept) { row in
                    autoKeepRow(row)
                }
            }

            // The badge on the collapsed row in the reference design. It stays visible folded up,
            // because a refusal is the part of the pass a person most needs to know happened.
            if let reason = snapshot.heldBackReason, let held = snapshot.heldBack.first {
                Label(
                    snapshot.heldBack.count == 1
                        ? "Left \(held.title) for you — \(reason)."
                        : "Left \(snapshot.heldBack.count) for you — \(reason).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ochre)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("missionAutoKeepHeldBack.\(snapshot.id)")
            }
        }
        .padding(CrumbMetrics.Space.m)
        .background(
            CrumbColor.pineSoft,
            in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private func autoKeepRow(_ row: MissionAutoKeepRow) -> some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The part is the *reason* this one was taken, which is the question a receipt for
                // an unwatched decision has to answer.
                Text([row.part, row.merchant].compactMap { $0 }.joined(separator: " · "))
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: CrumbMetrics.Space.xs)
            Text(row.presentedPrice, format: .currency(code: "USD"))
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.title), \(row.presentedPrice.formatted(.currency(code: "USD"))), from \(row.merchant)"
                + (row.part.map { ", for \($0)" } ?? "")
        )
        .accessibilityIdentifier("missionAutoKeepRow.\(row.productID)")
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
