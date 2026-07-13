import SwiftUI
import CrumbKit
import CrumbArt

/// The sole response surface for a mission conversation. Assistant turns and their artifacts are
/// read-only; every option, recovery action, and typed reply enters through this dock.
struct MissionResponseDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var text = ""
    @State private var submittedInteractionID: String?
    @FocusState private var focused: Bool

    private var state: MissionDockState { model.missionDockState }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            if state.mode == .working {
                Label(state.question, systemImage: "sparkles")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                    .accessibilityIdentifier("missionResponseWorking")
            } else if state.mode == .recovery {
                Label(state.question, systemImage: "exclamationmark.icloud")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ochre)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("missionResponseRecovery")
            }

            if !state.options.isEmpty {
                MissionResponseOptions(
                    options: state.options,
                    stacksVertically: dynamicTypeSize.isAccessibilitySize,
                    isEnabled: optionsEnabled,
                    onSelect: submit(option:)
                )
            }

            MissionTextInputRow(
                text: $text,
                focused: $focused,
                placeholder: state.placeholder,
                isEnabled: textEnabled,
                onSubmit: submitText
            )
        }
        .padding(.horizontal, CrumbMetrics.Space.l)
        .padding(.top, CrumbMetrics.Space.m)
        .padding(.bottom, CrumbMetrics.Space.s)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().foregroundStyle(CrumbColor.line) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Response to Crumb: \(state.question)")
        .accessibilityIdentifier("missionResponseDock")
        .onChange(of: state.interaction?.id) {
            submittedInteractionID = nil
        }
    }

    private var interactionWasSubmitted: Bool {
        guard let id = state.interaction?.id else { return false }
        return submittedInteractionID == id
    }

    private var optionsEnabled: Bool { state.isEnabled && !interactionWasSubmitted }
    private var textEnabled: Bool {
        state.isEnabled && state.allowsFreeText && !interactionWasSubmitted
    }

    private func submit(option: MissionInteractionOption) {
        guard optionsEnabled else { return }
        // Recovery actions may legitimately fail and need another attempt without changing the
        // underlying interaction id. Only ordinary semantic answers use the duplicate-tap latch.
        if state.mode != .recovery { submittedInteractionID = state.interaction?.id }
        focused = false
        model.submitMissionOption(option.id)
    }

    private func submitText() {
        let value = text.trimmed
        guard textEnabled, !value.isEmpty else { return }
        submittedInteractionID = state.interaction?.id
        focused = false
        model.submitMissionText(value)
        text = ""
    }
}

private struct MissionResponseOptions: View {
    let options: [MissionInteractionOption]
    let stacksVertically: Bool
    let isEnabled: Bool
    let onSelect: (MissionInteractionOption) -> Void

    var body: some View {
        Group {
            if stacksVertically {
                ScrollView(.vertical) {
                    VStack(spacing: CrumbMetrics.Space.s) { optionButtons }
                }
                .frame(maxHeight: 210)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: CrumbMetrics.Space.s) { optionButtons }
                    VStack(spacing: CrumbMetrics.Space.s) { optionButtons }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionResponseOptions")
    }

    @ViewBuilder
    private var optionButtons: some View {
        ForEach(options) { option in
            Button { onSelect(option) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(CrumbType.captionStrong)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(CrumbType.caption)
                            .foregroundStyle(CrumbColor.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(CrumbColor.ink)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, CrumbMetrics.Space.m)
                .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                        .strokeBorder(CrumbColor.line, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityIdentifier("missionResponseOption.\(option.id)")
        }
    }
}

private struct MissionTextInputRow: View {
    @Binding var text: String
    let focused: FocusState<Bool>.Binding
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            CrumbBadge(size: 24)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(1...3)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSubmit)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
                .disabled(!isEnabled)
                .accessibilityIdentifier("missionResponseField")

            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSubmit ? CrumbColor.pine : CrumbColor.ink3, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Send response")
            .accessibilityIdentifier("missionResponseSend")
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: focused.wrappedValue ? 1.5 : 1)
        )
        .opacity(isEnabled ? 1 : 0.7)
    }

    private var canSubmit: Bool { isEnabled && !text.trimmed.isEmpty }
}
