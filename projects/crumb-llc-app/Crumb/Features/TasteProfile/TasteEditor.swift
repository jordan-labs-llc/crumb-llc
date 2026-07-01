import SwiftUI
import CrumbKit

/// Suggested starting vocabulary for the taste chips — quick taps so a user isn't staring at
/// an empty field. Not exhaustive or prescriptive: anything can be typed in, and these are
/// just the common shapes of the seed persona.
enum TasteVocabulary {
    static let vibe = [
        "Quiet", "Earthy", "Built to last", "Warm", "Minimal",
        "Playful", "Refined", "Rugged", "Bright", "Cozy",
    ]
    static let leanings = [
        "Merino over synthetic", "Muted tones", "Fewer better things",
        "Natural materials", "Local makers", "Repairable", "Secondhand-first",
        "Bold color", "Tech-forward",
    ]
}

// MARK: - Editable chips

/// A titled section of removable chips plus an add affordance: tap an existing chip to remove
/// it, tap a suggestion to add it, or type a custom one. The core manual editing surface,
/// shared by onboarding and the taste sheet.
struct EditableChipSection: View {
    let title: String
    let tint: Color
    @Binding var items: [String]
    var suggestions: [String] = []

    @State private var draft = ""

    private var available: [String] {
        suggestions.filter { suggestion in
            !items.contains { $0.caseInsensitiveCompare(suggestion) == .orderedSame }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text(title)
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)

            if items.isEmpty {
                Text("Nothing yet — add a few below.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
            } else {
                FlexibleWrap(spacing: CrumbMetrics.Space.s) {
                    ForEach(items, id: \.self) { item in
                        RemovableChip(text: item, tint: tint) { remove(item) }
                    }
                }
            }

            addField

            if !available.isEmpty {
                FlexibleWrap(spacing: CrumbMetrics.Space.s) {
                    ForEach(available, id: \.self) { suggestion in
                        SuggestionChip(text: suggestion) { add(suggestion) }
                    }
                }
            }
        }
    }

    private var addField: some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            TextField("Add your own…", text: $draft)
                .textFieldStyle(.plain)
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink)
                .submitLabel(.done)
                .onSubmit { add(draft) }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                #endif
            Button {
                add(draft)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(draft.trimmed.isEmpty ? CrumbColor.ink3 : tint)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmed.isEmpty)
            .accessibilityLabel("Add \(title.lowercased())")
        }
        .padding(.horizontal, CrumbMetrics.Space.m)
        .padding(.vertical, CrumbMetrics.Space.s)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
    }

    private func add(_ value: String) {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty,
              !items.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { draft = ""; return }
        items.append(trimmed)
        draft = ""
    }

    private func remove(_ value: String) {
        items.removeAll { $0 == value }
    }
}

/// A chip the user can tap to remove (a small xmark trails the label).
private struct RemovableChip: View {
    let text: String
    let tint: Color
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: CrumbMetrics.Space.xs) {
                Text(text)
                    .font(CrumbType.pill)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, CrumbMetrics.Space.m)
            .padding(.vertical, CrumbMetrics.Space.s)
            .background(CrumbColor.pineSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(text). Remove.")
    }
}

/// A dashed "+" suggestion chip that adds its label on tap.
private struct SuggestionChip: View {
    let text: String
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: CrumbMetrics.Space.xs) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.bold))
                Text(text)
                    .font(CrumbType.pill)
            }
            .foregroundStyle(CrumbColor.ink2)
            .padding(.horizontal, CrumbMetrics.Space.m)
            .padding(.vertical, CrumbMetrics.Space.s)
            .background(
                Capsule().strokeBorder(CrumbColor.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(text)")
    }
}

// MARK: - Budget slider

/// A labeled budget-comfort slider (`0…1`, thrifty ↔ splurge).
struct BudgetComfortSlider: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            HStack {
                Text("Budget comfort")
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1) {
                Text("Budget comfort")
            }
            .tint(CrumbColor.ochre)
            Text("Thrifty ↔ Splurge")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Budget comfort")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.1)
            case .decrement: value = max(0, value - 0.1)
            @unknown default: break
            }
        }
    }
}

// MARK: - Signature editor

/// The free-text "in your words" signature line.
struct SignatureEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text("Your signature")
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)
            TextField(
                "You'd rather own three things you love than ten you tolerate.",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(CrumbType.curator)
            .foregroundStyle(CrumbColor.ink)
            .lineLimit(2...4)
            .padding(CrumbMetrics.Space.m)
            .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                    .strokeBorder(CrumbColor.line, lineWidth: 1)
            )
        }
    }
}

// MARK: - Describe yourself (AI parse)

/// The AI accelerator: a free-text box that reads a self-description into the draft via the
/// injected ``TasteExtractor``. On success it tops up the chips/slider/signature (which the
/// user can still hand-tune); when no model is available it degrades honestly to "set it by
/// hand below" — the manual editors are always present, so this only ever helps.
struct DescribeYourselfCard: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: TasteProfile

    @State private var text = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case reading
        case applied
        case noModel   // extractor returned nil — manual fallback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Label("Describe your taste", systemImage: "sparkles")
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)

            Text("Tell me in a sentence or two and I'll fill this in — then tweak anything.")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "I like quiet, earthy gear that lasts. Merino over synthetic, muted tones…",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(CrumbType.body)
            .foregroundStyle(CrumbColor.ink)
            .lineLimit(2...5)
            .padding(CrumbMetrics.Space.m)
            .background(CrumbColor.paper, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                    .strokeBorder(CrumbColor.line, lineWidth: 1)
            )

            HStack(spacing: CrumbMetrics.Space.s) {
                Button(action: read) {
                    HStack(spacing: CrumbMetrics.Space.s) {
                        if phase == .reading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(phase == .reading ? "Reading…" : "Read my taste")
                            .font(CrumbType.headline)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, CrumbMetrics.Space.l)
                    .padding(.vertical, CrumbMetrics.Space.s)
                    .background(CrumbColor.pine, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(text.trimmed.isEmpty || phase == .reading)
                .opacity(text.trimmed.isEmpty || phase == .reading ? 0.6 : 1)

                statusLabel
                Spacer(minLength: 0)
            }
        }
        .crumbCard()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch phase {
        case .applied:
            Label("Filled in below", systemImage: "checkmark.circle.fill")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.pine)
                .labelStyle(.titleAndIcon)
        case .noModel:
            Text("Couldn't read it here — set it by hand below.")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            // Explain why the button is dimmed until there's something to read (issue #28).
            if text.trimmed.isEmpty {
                Text("Type a sentence above to enable.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .reading:
            EmptyView()
        }
    }

    private func read() {
        let input = text.trimmed
        guard !input.isEmpty else { return }
        phase = .reading
        Task {
            let parsed = await model.extractTaste(from: input, base: draft)
            if let parsed {
                draft = parsed
                phase = .applied
            } else {
                phase = .noModel
            }
        }
    }
}

// MARK: - Small helpers

extension String {
    /// Whitespace-trimmed copy — used across the taste editors for add/validate.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
