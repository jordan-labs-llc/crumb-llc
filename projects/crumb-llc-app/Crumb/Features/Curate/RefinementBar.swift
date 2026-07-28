import SwiftUI
import CrumbKit
import CrumbArt

/// Crumb's sole conversational input surface. The same envelope starts a mission and answers the
/// current thread question; assistant turns and their artifacts remain read-only scrollback.
struct MissionResponseDock: View {
    enum Mode {
        case activeMission
        case newMission
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let mode: Mode

    @State private var drafts: [ComposerIdentity: String] = [:]
    @State private var submittedIdentity: ComposerIdentity?
    @State private var expandedChoices: MissionChoicePresentation?
    @State private var pendingDestructive: PendingDestructiveChoice?
    @State private var addingPerson = false
    /// Whether the person has opened the prose field on a question that also offers buttons.
    /// Reset with `identity`, so it never carries across to a different question.
    @State private var isComposingProse = false
    @FocusState private var focused: Bool

    init(mode: Mode = .activeMission) {
        self.mode = mode
    }

    /// Shown only to someone with no recent goals of their own. These used to be unconditional, so a
    /// person on their fortieth mission was still being offered "Premium jasmine tea" as an example.
    private static let starterExamples: [MissionStarterSuggestion] = [
        MissionStarterSuggestion(id: "jasmine-tea", label: "Premium jasmine tea", prompt: "Find premium jasmine tea"),
        MissionStarterSuggestion(id: "pour-over", label: "Pour-over corner", prompt: "Set up my pour-over corner"),
        MissionStarterSuggestion(id: "rainy-hike", label: "Rainy hike", prompt: "Pack me for a rainy weekend hike"),
    ]

    /// Your own recent goals when there are any, the teaching examples otherwise.
    ///
    /// `AppModel.recentGoals` has been loaded at launch and written after every mission since the
    /// recents store was added, and until now no view read it — a whole persisted store with no
    /// surface, while the space it belongs in held three hardcoded strings.
    private var newMissionSuggestions: [MissionStarterSuggestion] {
        let recents = model.recentGoals.prefix(3)
        guard !recents.isEmpty else { return Self.starterExamples }
        return recents.enumerated().map { index, goal in
            MissionStarterSuggestion(id: "recent-\(index)", label: goal, prompt: goal)
        }
    }

    private var state: MissionDockState? {
        guard case .activeMission = mode else { return nil }
        return model.missionDockState
    }

    private var identity: ComposerIdentity {
        switch mode {
        case .newMission:
            return .newMission
        case .activeMission:
            let interaction = state?.interaction
            return ComposerIdentity(
                threadID: model.activeThreadID,
                interactionID: interaction?.id,
                interactionGeneration: interaction?.interactionGeneration,
                subjectRevision: interaction?.subjectRevision,
                recovery: state?.showsSaveRecovery == true ? model.activeThread?.blockingRecovery : nil,
                recoveryRevision: state?.showsSaveRecovery == true ? model.activeThread?.revision : nil
            )
        }
    }

    private var draft: Binding<String> {
        let key = identity
        return Binding(
            get: { drafts[key, default: ""] },
            set: { drafts[key] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
                switch mode {
                case .activeMission:
                    activeMissionContents
                case .newMission:
                    newMissionContents
                }
            }
            .padding(CrumbMetrics.Space.m)
            .background(
                CrumbColor.raised,
                in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                    .strokeBorder(focused ? CrumbColor.pine : CrumbColor.line, lineWidth: focused ? 1.5 : 1)
            }
            .crumbShadow()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("missionResponseDock")
        }
        .padding(.horizontal, CrumbMetrics.Space.l)
        .padding(.top, CrumbMetrics.Space.s)
        .padding(.bottom, CrumbMetrics.Space.s)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().foregroundStyle(CrumbColor.line) }
        .onChange(of: identity) { oldIdentity, _ in
            // A draft, an open chooser and an unanswered confirmation all belong to one exact
            // frozen question. Never let any of them visually migrate to a replacement interaction
            // or another thread — a stale "End this mission?" would end the *new* one.
            drafts[oldIdentity] = nil
            submittedIdentity = nil
            expandedChoices = nil
            pendingDestructive = nil
            isComposingProse = false
        }
        .confirmationDialog(
            "End this mission?",
            isPresented: Binding(
                get: { pendingDestructive != nil },
                set: { if !$0 { pendingDestructive = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDestructive
        ) { choice in
            // Deliberately not `choice.option.label`: the retry question's destructive option is
            // labelled "Cancel", which under "End this mission?" reads as "cancel the dialog".
            Button("End mission", role: .destructive) {
                commit(option: choice.option, context: choice.context)
                pendingDestructive = nil
            }
            .accessibilityIdentifier("missionEndConfirm")
            Button("Keep shopping", role: .cancel) { pendingDestructive = nil }
        } message: { _ in
            Text(endMissionWarning)
        }
        .sheet(item: $expandedChoices) { presentation in
            MissionChoiceSheet(
                presentation: presentation,
                isEnabled: identity == presentation.identity && optionsEnabled
            ) { option in
                submit(option: option, context: presentation.context, presentedIdentity: presentation.identity)
                expandedChoices = nil
            }
        }
        .sheet(isPresented: $addingPerson) {
            PersonEditorView(existing: nil) { saved in
                model.composerRecipient = saved
            }
            .crumbExpandableSheet()
        }
    }

    // MARK: Active mission

    @ViewBuilder
    private var activeMissionContents: some View {
        if let state {
            if let warning = model.threadPersistenceWarning, state.showsSaveRecovery == false {
                contextLabel(warning, systemImage: "exclamationmark.triangle", color: CrumbColor.ochre)
                    .accessibilityIdentifier("missionResponseWarning")
            }

            if state.mode == .working {
                contextLabel(state.question, systemImage: "sparkles", color: CrumbColor.ink2)
                    .accessibilityIdentifier("missionResponseWorking")
            } else if state.mode == .recovery {
                contextLabel(state.question, systemImage: "exclamationmark.icloud", color: CrumbColor.ochre)
                    .accessibilityIdentifier("missionResponseRecovery")
            } else if state.mode == .confirmation {
                Text(state.question)
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("missionResponseConfirmation")
            }

            if !state.options.isEmpty {
                MissionResponseOptions(
                    question: state.question,
                    options: state.options,
                    usesDisclosure: dynamicTypeSize.isAccessibilitySize || state.options.contains(where: hasLongDetail),
                    isEnabled: optionsEnabled,
                    identity: identity,
                    context: submissionContext,
                    onSelect: submit(option:context:presentedIdentity:),
                    onExpand: { presentation in expandedChoices = presentation }
                )
            }

            // A choice-only or confirmation question deliberately has no inert text field. The
            // envelope contains only the controls that can answer the current question.
            //
            // When the question *does* offer buttons, the field is folded behind "Tell Crumb
            // more". Standing open beside them it read as the primary way to answer — which is how
            // a session ends up typing "Let's create a cart" at a dock whose buttons were "Find
            // more" and "End mission". Buttons carry the common moves; prose is for the things a
            // button cannot say. A question with no buttons keeps the field inline, because then
            // it is the only way to answer at all.
            if state.allowsFreeText {
                if state.options.isEmpty || isComposingProse {
                    if !state.options.isEmpty { Divider().foregroundStyle(CrumbColor.line) }
                    MissionTextInputRow(
                        text: draft,
                        focused: $focused,
                        placeholder: state.placeholder,
                        isEnabled: textEnabled,
                        fieldIdentifier: "missionResponseField",
                        sendIdentifier: "missionResponseSend",
                        onSubmit: submitText
                    )
                } else {
                    Button {
                        isComposingProse = true
                        focused = true
                    } label: {
                        Label("Tell Crumb more", systemImage: "text.bubble")
                            .font(CrumbType.caption)
                            .foregroundStyle(CrumbColor.ink3)
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!textEnabled)
                    .accessibilityHint("Opens a field to answer in your own words")
                    .accessibilityIdentifier("missionResponseComposeProse")
                }
            }
        }
    }

    private var interactionWasSubmitted: Bool {
        submittedIdentity == identity
    }

    private var optionsEnabled: Bool {
        state?.isEnabled == true && !interactionWasSubmitted
    }

    private var textEnabled: Bool {
        state?.isEnabled == true && state?.allowsFreeText == true && !interactionWasSubmitted
    }

    private var submissionContext: MissionSubmissionContext? {
        guard let threadID = model.activeThreadID, let interaction = state?.interaction else { return nil }
        return MissionSubmissionContext(
            threadID: threadID,
            interactionID: interaction.id,
            interactionGeneration: interaction.interactionGeneration,
            subjectRevision: interaction.subjectRevision
        )
    }

    /// What ending costs, said plainly. The app already treats destroying a mission as
    /// confirmation-worthy on the deliberate path (long-press a Home row → Delete); this is the
    /// accidental one. Now that ending also writes History, the honest message is mostly
    /// reassurance — which is exactly why it should be shown rather than assumed.
    private var endMissionWarning: String {
        let kept = model.kit.count
        guard kept > 0 else { return "This mission stops here. You haven't kept anything yet." }
        let picks = kept == 1 ? "pick" : "picks"
        return "Your \(kept) \(picks) are saved to History. This mission stops here — Crumb won't keep shopping for it."
    }

    private func submit(
        option: MissionInteractionOption,
        context: MissionSubmissionContext?,
        presentedIdentity: ComposerIdentity
    ) {
        guard optionsEnabled, identity == presentedIdentity else { return }
        focused = false

        if state?.showsSaveRecovery == true {
            // Persistence recovery is the only synthetic dock state: its options intentionally sit
            // in front of the unanswered durable interaction rather than resolving it.
            guard identity.threadID == model.activeThreadID else { return }
            if option.id == "save-again" { model.retryThreadPersistence() }
            if option.id == "discard" { model.discardUnsavedThreadChanges() }
            return
        }

        // Ending a mission is the one dock answer that can't be walked back by answering again.
        guard !option.isDestructive else {
            pendingDestructive = PendingDestructiveChoice(
                option: option, context: context, identity: presentedIdentity
            )
            return
        }
        commit(option: option, context: context)
    }

    /// The write itself. Split out of ``submit(option:context:presentedIdentity:)`` so a confirmed
    /// destructive choice re-enters here without re-running the tap-time gating — the frozen
    /// identity check below is what actually keeps a stale answer out.
    private func commit(option: MissionInteractionOption, context: MissionSubmissionContext?) {
        guard let context else { return }
        let submittedContextIdentity = context.composerIdentity
        guard identity == submittedContextIdentity else { return }
        switch model.submitMissionAnswer(context.submission(answer: .option(id: option.id))) {
        case .applied:
            submittedIdentity = submittedContextIdentity
        case .unsaved, .rejected:
            // Recovery choices must remain live after an unsaved commit, and a rejected stale
            // answer must never strand the current composer in a disabled state.
            submittedIdentity = nil
        }
    }

    private func submitText() {
        let key = identity
        let value = drafts[key, default: ""].trimmed
        guard textEnabled, !value.isEmpty, let context = submissionContext else { return }
        focused = false
        switch model.submitMissionAnswer(context.submission(answer: .freeText(value))) {
        case .applied:
            submittedIdentity = key
            drafts[key] = nil
        case .unsaved:
            submittedIdentity = nil
            drafts[key] = nil
        case .rejected:
            // A reducer or stale-context rejection is retryable. Preserve what the person typed.
            submittedIdentity = nil
        }
    }

    // MARK: New mission

    /// True once Home has any mission to show. The dock then collapses to a single line: with work on
    /// screen the greeting, the recipient control and the starter chips are all competing with content
    /// that earned the space, and the field alone still says what it wants.
    private var isCollapsed: Bool {
        guard case .newMission = mode else { return false }
        return !model.incompleteThreads.isEmpty
    }

    /// Collapsed, the field is the only thing left, so it has to carry the invitation the greeting was
    /// carrying above it.
    private var newMissionPlaceholder: String {
        if model.isPlanning { return "Starting your mission…" }
        return isCollapsed ? "Start something new…" : "Describe it in your own words…"
    }

    private var newMissionContents: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            if !isCollapsed {
                HStack(spacing: CrumbMetrics.Space.s) {
                    newMissionRecipientAccessory
                    Spacer(minLength: 0)
                }

                newMissionSuggestionChoices
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("newMissionSuggestions")

                Divider().foregroundStyle(CrumbColor.line)
            }

            MissionTextInputRow(
                text: draft,
                focused: $focused,
                placeholder: newMissionPlaceholder,
                isEnabled: !model.isPlanning,
                fieldIdentifier: "missionResponseField",
                sendIdentifier: "missionResponseSend",
                onSubmit: submitNewMission
            )
        }
        .onAppear {
            // An empty landing is an invitation: the cursor is already in the conversation, so
            // the first thing a person does is talk. With missions to continue, the list keeps
            // the floor and the keyboard stays down.
            guard model.incompleteThreads.isEmpty, !model.isPlanning else { return }
            #if DEBUG
            guard ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] == nil else { return }
            #endif
            focused = true
        }
    }

    @ViewBuilder
    private var newMissionSuggestionChoices: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Menu {
                ForEach(newMissionSuggestions) { suggestion in
                    Button(suggestion.label) { stage(suggestion) }
                }
            } label: {
                Label("Try an example", systemImage: "wand.and.stars")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(model.isPlanning)
            .accessibilityIdentifier("newMissionSuggestionMenu")
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CrumbMetrics.Space.xs) {
                    suggestionButtons
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CrumbMetrics.Space.xs) {
                        suggestionButtons
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionButtons: some View {
        ForEach(newMissionSuggestions) { suggestion in
            Button { stage(suggestion) } label: {
                Text(suggestion.label)
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44, alignment: .leading)
                    .padding(.horizontal, CrumbMetrics.Space.s)
                    .background(CrumbColor.pineSoft, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isPlanning)
            .accessibilityHint("Stages this example in the message field without sending it")
            .accessibilityIdentifier("newMissionSuggestion.\(suggestion.id)")
        }
    }

    private func stage(_ suggestion: MissionStarterSuggestion) {
        drafts[.newMission] = suggestion.prompt
        focused = true
    }

    private var newMissionRecipientAccessory: some View {
        Menu {
            Button {
                model.composerRecipient = nil
            } label: {
                Label("You", systemImage: model.composerRecipient == nil ? "checkmark" : "person.crop.circle")
            }

            ForEach(model.recipients) { recipient in
                Button {
                    model.composerRecipient = recipient
                } label: {
                    Label(recipient.name, systemImage: model.composerRecipient?.id == recipient.id ? "checkmark" : "person")
                }
            }

            Divider()

            Button {
                addingPerson = true
            } label: {
                Label("Add someone", systemImage: "person.badge.plus")
            }
        } label: {
            // This used to read "For you" with a gift glyph, in caption weight, directly above the
            // chip row — so the one control that changes who a mission is for looked like a section
            // heading *for* the chips. Naming the action and showing a disclosure chevron is what
            // makes it read as something you can tap.
            HStack(spacing: 3) {
                Text("Shopping for")
                    .foregroundStyle(CrumbColor.ink3)
                Text(model.composerRecipient?.name ?? "You")
                    .foregroundStyle(CrumbColor.ink)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(CrumbColor.ink3)
            }
            .font(CrumbType.captionStrong)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Shopping for \(model.composerRecipient?.name ?? "yourself")")
        .accessibilityIdentifier("composerRecipientAccessory")
    }

    private func submitNewMission() {
        let value = drafts[.newMission, default: ""].trimmed
        guard !model.isPlanning, !value.isEmpty else { return }
        focused = false
        drafts[.newMission] = nil
        model.planMission(goal: value, for: model.composerRecipient)
    }

    private func contextLabel(_ text: String, systemImage: String, color: Color) -> some View {
        // The symbol is decoration; only the text is the status. Hiding the icon leaves one
        // accessibility element instead of two, so a caller's identifier can no longer land on both
        // an Image labelled "Sparkle" and the text — and VoiceOver stops announcing the symbol as
        // its own stop. Hiding the icon rather than merging the pair keeps the text's static-text
        // role, which `.accessibilityElement(children: .ignore)` would discard.
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(CrumbType.captionStrong)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A detail long enough that it cannot ride a capsule and needs the expanded chooser.
    /// A price ("$36.00") rides; a sentence does not.
    private func hasLongDetail(_ option: MissionInteractionOption) -> Bool {
        (option.detail?.count ?? 0) > 16
    }
}

private struct MissionResponseOptions: View {
    let question: String
    let options: [MissionInteractionOption]
    let usesDisclosure: Bool
    let isEnabled: Bool
    let identity: ComposerIdentity
    let context: MissionSubmissionContext?
    let onSelect: (MissionInteractionOption, MissionSubmissionContext?, ComposerIdentity) -> Void
    let onExpand: (MissionChoicePresentation) -> Void

    /// The things you can do *inside* a mission. These are the peers.
    private var choices: [MissionInteractionOption] {
        options.filter { !$0.isDestructive }
    }

    /// Ending is not one of them.
    private var enders: [MissionInteractionOption] {
        options.filter(\.isDestructive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
            if !choices.isEmpty {
                if usesDisclosure {
                    disclosureChoices
                } else {
                    compactChoices
                }
            }

            // "End mission" used to be the third capsule in [Review cart] [Find more] [End
            // mission] — same tint, same size, one thumb-width from "Find more", and the only one
            // of the three you couldn't undo. It gets its own line, no fill and quieter type so
            // the row above reads as the choices and this reads as the exit.
            ForEach(enders) { option in
                enderButton(option)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionResponseOptions")
    }

    private var compactChoices: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: CrumbMetrics.Space.xs) {
                compactOptionButtons
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CrumbMetrics.Space.xs) {
                    compactOptionButtons
                }
                .padding(.vertical, 1)
            }
        }
    }

    @ViewBuilder
    private var compactOptionButtons: some View {
        ForEach(choices) { option in
            compactButton(option)
        }
    }

    private var disclosureChoices: some View {
        Button {
            onExpand(MissionChoicePresentation(
                question: question,
                options: choices,
                context: context,
                identity: identity
            ))
        } label: {
            HStack(spacing: CrumbMetrics.Space.s) {
                Label("Choose a response", systemImage: "list.bullet")
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.right.square")
                    .accessibilityHidden(true)
            }
            .font(CrumbType.captionStrong)
            .foregroundStyle(CrumbColor.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint("Opens response choices")
        .accessibilityIdentifier("missionResponseChoiceDisclosure")
    }

    /// The capsule's text: the label, plus a short detail when there is one.
    private func compactTitle(_ option: MissionInteractionOption) -> String {
        guard let detail = option.detail, !detail.isEmpty, detail.count <= 16 else { return option.label }
        return "\(option.label) \u{00B7} \(detail)"
    }

    private func compactButton(_ option: MissionInteractionOption) -> some View {
        Button { onSelect(option, context, identity) } label: {
            // A short detail rides the chip: "Add to cart · $36", "Cheaper · $24". It used to force
            // the whole row behind a "Choose a response" disclosure, which buried the primary
            // action two taps deep — a worse trade than a slightly wider capsule.
            Text(compactTitle(option))
                .font(CrumbType.captionStrong)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.84)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .padding(.horizontal, CrumbMetrics.Space.s)
                .background(CrumbColor.pineSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Spoken with a comma rather than the visible "·", which VoiceOver reads as "middle dot".
        .accessibilityLabel(
            option.detail.map { detail in
                detail.isEmpty || detail.count > 16 ? option.label : "\(option.label), \(detail)"
            } ?? option.label
        )
        .accessibilityIdentifier("missionResponseOption.\(option.id)")
    }

    /// Deliberately not a capsule: no fill, no border, secondary ink, plain caption weight. It
    /// keeps the 44pt target and the same identifier the chip had, so VoiceOver and the UI tests
    /// still reach it — it just stops competing with the answers.
    private func enderButton(_ option: MissionInteractionOption) -> some View {
        Button { onSelect(option, context, identity) } label: {
            Text(option.label)
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint("Ends this mission. Asks you to confirm first.")
        .accessibilityIdentifier("missionResponseOption.\(option.id)")
    }
}

/// The expanded choice surface belongs to the composer, but gets a bounded, scrollable sheet so
/// accessibility text never pushes the message field or actions beyond the viewport.
private struct MissionChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: MissionChoicePresentation
    let isEnabled: Bool
    let onSelect: (MissionInteractionOption) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
                    Text(presentation.question)
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("missionResponseChoiceQuestion")

                    ForEach(presentation.options) { option in
                        Button { onSelect(option) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(CrumbType.captionStrong)
                                if let detail = option.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(CrumbType.caption)
                                        .foregroundStyle(CrumbColor.ink2)
                                }
                            }
                            .foregroundStyle(CrumbColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(CrumbMetrics.Space.m)
                            .background(
                                CrumbColor.pineSoft,
                                in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isEnabled)
                        .accessibilityIdentifier("missionResponseOption.\(option.id)")
                    }
                }
                .padding(CrumbMetrics.Space.l)
            }
            .navigationTitle("Choose a response")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("missionResponseChoiceSheet")
    }
}

private struct MissionTextInputRow: View {
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
    let placeholder: String
    let isEnabled: Bool
    let fieldIdentifier: String
    let sendIdentifier: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            CrumbBadge(size: 24)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(1...4)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSubmit)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
                .disabled(!isEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier(fieldIdentifier)

            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(canSubmit ? CrumbColor.pine : CrumbColor.ink3, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Send response")
            .accessibilityIdentifier(sendIdentifier)
        }
        .opacity(isEnabled ? 1 : 0.7)
    }

    private var canSubmit: Bool {
        isEnabled && !text.trimmed.isEmpty
    }
}

/// A destructive option the person tapped but has not confirmed. It carries the frozen submission
/// context with it, so confirming answers *that* question — never whatever the dock has moved on to.
private struct PendingDestructiveChoice: Identifiable {
    let option: MissionInteractionOption
    let context: MissionSubmissionContext?
    let identity: ComposerIdentity

    var id: String { option.id }
}

private struct MissionSubmissionContext: Hashable {
    let threadID: String
    let interactionID: String
    let interactionGeneration: Int
    let subjectRevision: Int

    var composerIdentity: ComposerIdentity {
        ComposerIdentity(
            threadID: threadID,
            interactionID: interactionID,
            interactionGeneration: interactionGeneration,
            subjectRevision: subjectRevision,
            recovery: nil,
            recoveryRevision: nil
        )
    }

    func submission(answer: MissionInteractionAnswer) -> MissionInteractionSubmission {
        MissionInteractionSubmission(
            threadID: threadID,
            interactionID: interactionID,
            interactionGeneration: interactionGeneration,
            subjectRevision: subjectRevision,
            answer: answer
        )
    }
}

private struct ComposerIdentity: Hashable {
    static let newMission = ComposerIdentity(
        threadID: "new-mission",
        interactionID: nil,
        interactionGeneration: nil,
        subjectRevision: nil,
        recovery: nil,
        recoveryRevision: nil
    )

    let threadID: String?
    let interactionID: String?
    let interactionGeneration: Int?
    let subjectRevision: Int?
    let recovery: MissionBlockingRecovery?
    let recoveryRevision: Int?
}

private struct MissionChoicePresentation: Identifiable {
    let id = UUID()
    let question: String
    let options: [MissionInteractionOption]
    let context: MissionSubmissionContext?
    let identity: ComposerIdentity
}

private struct MissionStarterSuggestion: Identifiable {
    let id: String
    let label: String
    let prompt: String
}
