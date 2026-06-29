import SwiftUI
import CrumbKit
import CrumbArt

/// **People you shop for.** The roster behind the gift feature — each person a reusable entity with
/// their own saved taste, tinted by their accent. Reached from the app header's `person.2`
/// affordance. Add / edit / delete here (swipe + menu, like History); a warm `CrumbEmptyArt`
/// first-run state when the roster is empty.
///
/// "Yourself" is intentionally **not** here — that's the owner taste profile, edited from the
/// header's taste sheet. This screen is only the *other* people.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The editor sheet target: a new person, or an existing one being edited.
    @State private var editing: EditorTarget?

    private enum EditorTarget: Identifiable {
        case new
        case existing(Recipient)
        var id: String {
            switch self {
            case .new: return "new"
            case let .existing(recipient): return recipient.id
            }
        }
    }

    var body: some View {
        Group {
            if model.recipients.isEmpty {
                emptyState
            } else {
                roster
            }
        }
        .accessibilityIdentifier("PeopleScreen")
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                PersonEditorView(existing: nil)
                    .crumbExpandableSheet()
            case let .existing(recipient):
                PersonEditorView(existing: recipient)
                    .crumbExpandableSheet()
            }
        }
    }

    // MARK: Roster

    private var roster: some View {
        List {
            Section {
                header
                    .plainPeopleRow()
                    .padding(.bottom, CrumbMetrics.Space.xs)
            }

            Section {
                ForEach(Array(model.recipients.enumerated()), id: \.element.id) { index, recipient in
                    Button {
                        editing = .existing(recipient)
                    } label: {
                        PersonCard(recipient: recipient)
                    }
                    .buttonStyle(.plain)
                    .plainPeopleRow()
                    .crumbReveal(index: index, reduceMotion: reduceMotion)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteRecipient(id: recipient.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            editing = .existing(recipient)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            model.deleteRecipient(id: recipient.id)
                        } label: {
                            Label("Remove \(recipient.name)", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("PeopleRoster")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Text("People you shop for")
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)
            Text("Save someone and Crumb shops as *them* — their taste drives the whole kit. "
                + "Pick who a mission is for in the composer.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            addButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addButton: some View {
        Button {
            editing = .new
        } label: {
            HStack(spacing: CrumbMetrics.Space.s) {
                Image(systemName: "plus")
                Text("Add someone")
                    .font(CrumbType.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, CrumbMetrics.Space.l)
            .padding(.vertical, CrumbMetrics.Space.m)
            .background(CrumbColor.pine, in: Capsule())
            .crumbShadow()
        }
        .buttonStyle(.plain)
        .padding(.top, CrumbMetrics.Space.xs)
        .accessibilityIdentifier("addPersonButton")
    }

    // MARK: Empty / first-run state

    private var emptyState: some View {
        VStack(spacing: CrumbMetrics.Space.l) {
            Spacer()
            CrumbEmptyArt(variant: .nothingYet)
            Text("No people yet")
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)
            Text("Add the people you love to shop for — a partner, a parent, a friend — and Crumb "
                + "will curate to their taste, not yours. You become their shopper.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CrumbMetrics.Space.xl)
            Button {
                editing = .new
            } label: {
                Text("Add someone")
                    .font(CrumbType.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, CrumbMetrics.Space.xl)
                    .padding(.vertical, CrumbMetrics.Space.m)
                    .background(CrumbColor.pine, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, CrumbMetrics.Space.s)
            .accessibilityIdentifier("addPersonButton")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .accessibilityIdentifier("PeopleEmpty")
    }
}

// MARK: - Person card

/// One person on the roster: an accent-tinted avatar, their name + relationship, and a short read
/// of their taste (top vibe + leanings). Tapping opens the editor.
struct PersonCard: View {
    let recipient: Recipient

    private var accent: Color { Color(hex: recipient.accentHex) }

    var body: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.m) {
            PersonAvatar(name: recipient.name, accentHex: recipient.accentHex, size: 56)

            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
                Text(recipient.name)
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
                    .lineLimit(1)

                if let relationship = recipient.relationship?.trimmed, !relationship.isEmpty {
                    Text(relationship)
                        .font(CrumbType.curatorCaption)
                        .foregroundStyle(CrumbColor.ink2)
                        .lineLimit(1)
                }

                if !tasteLine.isEmpty {
                    Text(tasteLine)
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 4)
                .padding(.vertical, CrumbMetrics.Space.l)
        }
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .crumbShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// A compact read of their taste: the leading vibe + the first couple of leanings.
    private var tasteLine: String {
        let bits = (recipient.taste.vibe.prefix(1) + recipient.taste.leanings.prefix(2))
        return bits.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [recipient.name]
        if let relationship = recipient.relationship?.trimmed, !relationship.isEmpty { parts.append(relationship) }
        if !tasteLine.isEmpty { parts.append(tasteLine) }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Person avatar

/// An accent-tinted bubble carrying the person's initial over the brand crumb mark — on-brand art,
/// not an SF-symbol placeholder. Shared by the roster card, the composer picker, and History chips.
struct PersonAvatar: View {
    let name: String
    let accentHex: UInt32
    var size: CGFloat = 40

    private var accent: Color { Color(hex: accentHex) }

    private var initial: String {
        name.trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [accent, accent.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            CrumbMark()
                .fill(CrumbColor.paper.opacity(0.18))
                .padding(size * 0.16)
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .serif))
                .foregroundStyle(CrumbColor.paper)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Shared helpers

private extension View {
    /// Strips a List row of its chrome so a Crumb card floats on the paper board (mirrors History).
    func plainPeopleRow() -> some View {
        self
            .listRowInsets(EdgeInsets(
                top: CrumbMetrics.Space.xs, leading: CrumbMetrics.Space.xl,
                bottom: CrumbMetrics.Space.xs, trailing: CrumbMetrics.Space.xl
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
