import SwiftUI
import CrumbKit
import CrumbArt

/// The conversational-refinement bar pinned above the ``KitTray`` on the Curate screen — where
/// the user **talks back to the curator**. A free-text field ("tell Crumb what to change") for
/// open-ended asks, a row of quick chips fit to the mission (tea → Cheaper · Organic ·
/// Caffeine-free · Bolder; a hike → Cheaper · Warmer · Lighter · More durable) for the common
/// ones, a quiet opt-in to fold a refinement into their saved taste, and a Reset that undoes the
/// conversation.
///
/// Both the field and the chips route through `AppModel.refine(_:)` → the on-device
/// ``RefinementInterpreter``, so a chip tap and a typed line are read the same way. The chips
/// themselves come from `AppModel.refineChips` (the ``RefineChipSuggester`` seam), which fits them
/// to the mission's category so "Warmer"/"More durable" never show for a tea run (issue #25). They
/// are the discoverable, headless-screenshot-able affordance; the field is open-ended.
struct RefinementBar: View {
    @Environment(AppModel.self) private var model

    @State private var text: String = RefinementBar.seededText
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            inputRow
            chipRow
            if model.canSaveRefinementToTaste || !model.refinementTurns.isEmpty {
                actionRow
            }
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(focused ? CrumbColor.pine : CrumbColor.line, lineWidth: focused ? 1.5 : 1)
        )
        .crumbShadow()
        .padding(.horizontal, CrumbMetrics.Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("refinementBar")
    }

    // MARK: Field

    private var inputRow: some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            CrumbBadge(size: 24)
            TextField("tell Crumb what to change…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(1...3)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(submit)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("refinementField")
            submitButton
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Image(systemName: model.isReworking ? "ellipsis" : "arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(canSubmit ? CrumbColor.pine : CrumbColor.ink3, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .accessibilityLabel("Send refinement")
        .accessibilityIdentifier("refinementSubmit")
    }

    // MARK: Chips

    private var chipRow: some View {
        FlexibleWrap(spacing: CrumbMetrics.Space.s) {
            ForEach(model.refineChips) { chip in
                Button { apply(chip.refinementText) } label: {
                    Text(chip.label)
                        .font(CrumbType.pill)
                        .foregroundStyle(CrumbColor.pine)
                        .padding(.horizontal, CrumbMetrics.Space.m)
                        .padding(.vertical, CrumbMetrics.Space.s)
                        .background(CrumbColor.pineSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isReworking)
                .accessibilityIdentifier("refineChip.\(chip.id)")
            }
        }
    }

    // MARK: Save-to-taste / Reset

    private var actionRow: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            if !model.refinementTurns.isEmpty {
                Button("Reset") { model.resetRefinements() }
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resetRefinementsButton")
            }
            Spacer(minLength: 0)
            if model.canSaveRefinementToTaste {
                Button {
                    Task { await model.saveRefinementToTaste() }
                } label: {
                    Label(model.saveToTasteLabel, systemImage: "checkmark.circle")
                        .font(CrumbType.captionStrong)
                        .foregroundStyle(CrumbColor.ochre)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("saveRefinementToTasteButton")
            }
        }
        .padding(.top, CrumbMetrics.Space.xs)
    }

    // MARK: Actions

    private var canSubmit: Bool { !text.trimmed.isEmpty && !model.isReworking }

    private func submit() {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return }
        apply(trimmed)
    }

    /// Submits a refinement (typed or chip), clears the field, and drops focus.
    private func apply(_ refinement: String) {
        guard !model.isReworking else { return }
        focused = false
        text = ""
        model.refine(refinement)
    }

    /// In DEBUG screenshot mode, pre-fill the field from `CRUMB_REFINE` so the bar can be captured
    /// "mid-typing" — `simctl` can inject neither taps nor keystrokes.
    private static var seededText: String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] == "refine" {
            return ProcessInfo.processInfo.environment["CRUMB_REFINE"] ?? ""
        }
        #endif
        return ""
    }
}
