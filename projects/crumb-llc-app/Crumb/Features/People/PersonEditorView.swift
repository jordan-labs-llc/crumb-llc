import SwiftUI
import CrumbKit

/// Add or edit a person you shop for. Captures a name + free-text relationship, then their taste —
/// the **same** capture path the owner uses: a free-text "describe them" parse via
/// ``DescribeYourselfCard`` (which self-degrades to manual on the sim/CI) plus the hand-editable
/// chip / budget / signature editors from `TasteEditor.swift`. One consistent editor, reused.
///
/// `existing == nil` adds a new person (and, via `onSaved`, lets the composer immediately select
/// them); a non-nil `existing` edits in place and offers a Remove action.
struct PersonEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existing: Recipient?
    /// Called with the saved person — the composer uses it to select a freshly added recipient.
    var onSaved: ((Recipient) -> Void)?

    @State private var name: String
    @State private var relationship: String
    @State private var draft: TasteProfile

    init(existing: Recipient?, onSaved: ((Recipient) -> Void)? = nil) {
        self.existing = existing
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _relationship = State(initialValue: existing?.relationship ?? "")
        _draft = State(initialValue: existing?.taste ?? Self.blankTaste)
    }

    /// A new person starts from a clean slate (not the owner's taste) — you're describing *them*.
    private static let blankTaste = TasteProfile(
        vibe: [], leanings: [], budgetComfort: 0.5, signatureLine: ""
    )

    private var isEditing: Bool { existing != nil }
    private var canSave: Bool { !name.trimmed.isEmpty }

    var body: some View {
        BottomSheet(
            title: isEditing ? "Edit \(existing?.name ?? "person")" : "Add someone",
            subtitle: "Crumb will shop as them",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xl) {
                identityCard
                DescribeYourselfCard(draft: $draft)

                EditableChipSection(
                    title: "Vibe",
                    tint: CrumbColor.pine,
                    items: $draft.vibe,
                    suggestions: TasteVocabulary.vibe
                )
                EditableChipSection(
                    title: "Leanings",
                    tint: CrumbColor.ink2,
                    items: $draft.leanings,
                    suggestions: TasteVocabulary.leanings
                )
                BudgetComfortSlider(value: $draft.budgetComfort)
                SignatureEditor(text: $draft.signatureLine)

                saveButton
                if isEditing { deleteButton }
            }
            .padding(.top, CrumbMetrics.Space.m)
        }
    }

    // MARK: Identity (name + relationship)

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            field(title: "Name", placeholder: "Mom", text: $name, autocap: .words)
                .accessibilityIdentifier("personNameField")
            field(title: "Relationship (optional)", placeholder: "my mom", text: $relationship, autocap: .none)
            Text("Crumb uses the relationship in its voice — \u{201C}a gift for Mom.\u{201D}")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .crumbCard()
    }

    private func field(
        title: String,
        placeholder: String,
        text: Binding<String>,
        autocap: TextInputAutocapitalizationCompat
    ) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
            Text(title)
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .padding(CrumbMetrics.Space.m)
                .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                        .strokeBorder(CrumbColor.line, lineWidth: 1)
                )
                #if os(iOS)
                .textInputAutocapitalization(autocap == .words ? .words : .never)
                .autocorrectionDisabled(autocap == .words)
                #endif
        }
    }

    /// A tiny local enum so the helper reads the same on macOS (where the iOS modifiers are absent).
    private enum TextInputAutocapitalizationCompat { case words, none }

    // MARK: Actions

    private var saveButton: some View {
        Button(action: save) {
            HStack {
                Spacer()
                Text(isEditing ? "Save changes" : "Add to people")
                    .font(CrumbType.headline)
                Image(systemName: "checkmark")
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(CrumbMetrics.Space.l)
            .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .opacity(canSave ? 1 : 0.6)
            .crumbShadow()
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .padding(.top, CrumbMetrics.Space.s)
        .accessibilityIdentifier("savePersonButton")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let existing { model.deleteRecipient(id: existing.id) }
            dismiss()
        } label: {
            Label("Remove this person", systemImage: "trash")
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CrumbMetrics.Space.s)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("deletePersonButton")
    }

    private func save() {
        guard canSave else { return }
        let trimmedRelationship = relationship.trimmed.isEmpty ? nil : relationship.trimmed
        let saved: Recipient
        if let existing {
            var updated = existing
            updated.name = name.trimmed
            updated.relationship = trimmedRelationship
            updated.taste = draft
            model.updateRecipient(updated)
            saved = updated
        } else {
            saved = model.addRecipient(name: name.trimmed, relationship: trimmedRelationship, taste: draft)
        }
        onSaved?(saved)
        dismiss()
    }
}
