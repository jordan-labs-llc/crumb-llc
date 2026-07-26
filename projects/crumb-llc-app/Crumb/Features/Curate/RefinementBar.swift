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
    @State private var addingPerson = false
    @FocusState private var focused: Bool

    init(mode: Mode = .activeMission) {
        self.mode = mode
    }

    private static let newMissionSuggestions: [MissionStarterSuggestion] = [
        MissionStarterSuggestion(id: "jasmine-tea", label: "Premium jasmine tea", prompt: "Find premium jasmine tea"),
        MissionStarterSuggestion(id: "pour-over", label: "Pour-over corner", prompt: "Set up my pour-over corner"),
        MissionStarterSuggestion(id: "rainy-hike", label: "Rainy hike", prompt: "Pack me for a rainy weekend hike"),
    ]

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
            // A draft and an open chooser belong to one exact frozen question. Never let either
            // visually migrate to a replacement interaction or another thread.
            drafts[oldIdentity] = nil
            submittedIdentity = nil
            expandedChoices = nil
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
                    usesDisclosure: dynamicTypeSize.isAccessibilitySize || state.options.contains(where: hasDetail),
                    isEnabled: optionsEnabled,
                    identity: identity,
                    context: submissionContext,
                    onSelect: submit(option:context:presentedIdentity:),
                    onExpand: { presentation in expandedChoices = presentation }
                )
            }

            // A choice-only or confirmation question deliberately has no inert text field. The
            // envelope contains only the controls that can answer the current question.
            if state.allowsFreeText {
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

    private var newMissionContents: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack(spacing: CrumbMetrics.Space.s) {
                newMissionRecipientAccessory
                Spacer(minLength: 0)
            }

            newMissionSuggestionChoices
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("newMissionSuggestions")

            Divider().foregroundStyle(CrumbColor.line)

            MissionTextInputRow(
                text: draft,
                focused: $focused,
                placeholder: model.isPlanning ? "Starting your mission…" : "Describe it in your own words…",
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
                ForEach(Self.newMissionSuggestions) { suggestion in
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
        ForEach(Self.newMissionSuggestions) { suggestion in
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
            Label(model.composerRecipient?.name ?? "For you", systemImage: "gift")
                .font(CrumbType.captionStrong)
                .foregroundStyle(CrumbColor.ink2)
                .frame(minHeight: 44)
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
        Label(text, systemImage: systemImage)
            .font(CrumbType.captionStrong)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hasDetail(_ option: MissionInteractionOption) -> Bool {
        option.detail?.isEmpty == false
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

    var body: some View {
        Group {
            if usesDisclosure {
                disclosureChoices
            } else {
                compactChoices
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
        ForEach(options) { option in
            compactButton(option)
        }
    }

    private var disclosureChoices: some View {
        Button {
            onExpand(MissionChoicePresentation(
                question: question,
                options: options,
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

    private func compactButton(_ option: MissionInteractionOption) -> some View {
        Button { onSelect(option, context, identity) } label: {
            Text(option.label)
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
