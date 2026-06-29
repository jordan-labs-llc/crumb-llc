import SwiftUI
import CrumbKit

/// The composer's "Who's this for?" control — an inline row of chips: **You** (the owner, the
/// default), one per saved person (an accent-tinted initial bubble), and **Add someone**. One tap
/// sets ``AppModel/composerRecipient``; the mission that's then planned curates to that person.
/// Always defaults to You (gifting is opt-in per mission), and stays compact above the goal field.
struct RecipientPicker: View {
    @Environment(AppModel.self) private var model
    @State private var addingPerson = false

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Label("Who's this for?", systemImage: "gift")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CrumbMetrics.Space.s) {
                    youChip
                    ForEach(model.recipients) { recipient in
                        personChip(recipient)
                    }
                    addChip
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier("recipientPicker")
        .sheet(isPresented: $addingPerson) {
            // A freshly added person is selected immediately, so the mission you're about to plan is
            // for them.
            PersonEditorView(existing: nil) { saved in
                model.composerRecipient = saved
            }
            .crumbExpandableSheet()
        }
    }

    // MARK: Chips

    private var youChip: some View {
        chip(isSelected: model.composerRecipient == nil, accent: CrumbColor.pine, action: {
            model.composerRecipient = nil
        }) {
            HStack(spacing: CrumbMetrics.Space.xs) {
                Image(systemName: "person.crop.circle")
                Text("You")
            }
        }
        .accessibilityLabel("Shop for yourself")
        .accessibilityAddTraits(model.composerRecipient == nil ? .isSelected : [])
    }

    private func personChip(_ recipient: Recipient) -> some View {
        let selected = model.composerRecipient?.id == recipient.id
        return chip(isSelected: selected, accent: Color(hex: recipient.accentHex), action: {
            model.composerRecipient = recipient
        }) {
            HStack(spacing: CrumbMetrics.Space.xs) {
                PersonAvatar(name: recipient.name, accentHex: recipient.accentHex, size: 22)
                Text(recipient.name)
            }
        }
        .accessibilityLabel("Shop for \(recipient.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var addChip: some View {
        Button {
            addingPerson = true
        } label: {
            HStack(spacing: CrumbMetrics.Space.xs) {
                Image(systemName: "plus")
                Text("Add someone")
            }
            .font(CrumbType.pill)
            .foregroundStyle(CrumbColor.ink2)
            .padding(.horizontal, CrumbMetrics.Space.m)
            .padding(.vertical, CrumbMetrics.Space.s)
            .background(Capsule().strokeBorder(CrumbColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("addRecipientChip")
    }

    // MARK: Chip shell

    @ViewBuilder
    private func chip<Label: View>(
        isSelected: Bool,
        accent: Color,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .font(CrumbType.pill)
                .foregroundStyle(isSelected ? .white : CrumbColor.ink)
                .padding(.horizontal, CrumbMetrics.Space.m)
                .padding(.vertical, CrumbMetrics.Space.s)
                .background(
                    Group {
                        if isSelected {
                            Capsule().fill(accent)
                        } else {
                            Capsule().fill(CrumbColor.raised).overlay(Capsule().strokeBorder(CrumbColor.line, lineWidth: 1))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}
