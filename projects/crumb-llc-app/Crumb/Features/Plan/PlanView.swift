import SwiftUI
import CrumbKit

/// The Plan screen: the curator's serif note over the **editable** parts list (reword / remove /
/// add a part), an honest note if smart planning was unavailable, a "scanning shops" affordance
/// while candidates load, and the "Curate my kit" CTA that commits the edits and runs the search.
struct PlanView: View {
    @Environment(AppModel.self) private var model

    @State private var newPart = ""

    private var task: ShoppingTask? { model.selectedTask }

    var body: some View {
        if let task {
            content(for: task)
        } else {
            // Defensive: no mission selected — send the user home.
            ContentUnavailableView("No mission yet", systemImage: "questionmark.circle")
                .onAppear { model.goToMissions() }
        }
    }

    private func content(for task: ShoppingTask) -> some View {
        let accent = Color(hex: task.accentHex)
        return ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                header(for: task)

                CuratorNote(task.curatorNote, signoff: "Crumb", accent: accent)

                if let note = model.plannerFallbackNote {
                    plannerNote(note)
                }

                partsEditor

                scanRow

                Spacer(minLength: CrumbMetrics.Space.l)
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        .safeAreaInset(edge: .bottom) {
            curateCTA(accent: accent)
        }
        .accessibilityIdentifier("PlanScreen")
    }

    private func header(for task: ShoppingTask) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
            Text(task.title)
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)
            Text(task.subtitle)
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink2)
        }
    }

    // MARK: Editable parts

    private var partsEditor: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack {
                Text("The plan")
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Spacer()
                Text("Reword, remove, or add")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
            }

            if model.draftParts.isEmpty {
                Text("Add a part below to tell me what to look for.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
            } else {
                ForEach(model.draftParts) { part in
                    partRow(part)
                }
            }

            if model.draftParts.count < RuleBasedMissionPlanner.maxParts {
                addPartField
            }
        }
        .crumbCard()
    }

    private func partRow(_ part: PlanPart) -> some View {
        let binding = Binding(
            get: { part.label },
            set: { model.updatePart(part, label: $0) }
        )
        return HStack(spacing: CrumbMetrics.Space.m) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(CrumbColor.pine)
                .imageScale(.small)
                .accessibilityHidden(true)

            TextField("Part of the plan", text: binding)
                .textFieldStyle(.plain)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif

            Button {
                model.removePart(part)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(CrumbColor.ink3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(part.label)")
        }
        .padding(.vertical, CrumbMetrics.Space.xs)
    }

    private var addPartField: some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            Image(systemName: "plus")
                .font(.footnote.weight(.bold))
                .foregroundStyle(CrumbColor.ink3)
            TextField("Add a part…", text: $newPart)
                .textFieldStyle(.plain)
                .font(CrumbType.callout)
                .foregroundStyle(CrumbColor.ink)
                .submitLabel(.done)
                .onSubmit(commitNewPart)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
            Button(action: commitNewPart) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(newPart.trimmed.isEmpty ? CrumbColor.ink3 : CrumbColor.pine)
            }
            .buttonStyle(.plain)
            .disabled(newPart.trimmed.isEmpty)
            .accessibilityLabel("Add part")
        }
        .padding(.horizontal, CrumbMetrics.Space.m)
        .padding(.vertical, CrumbMetrics.Space.s)
        .background(CrumbColor.paper, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .accessibilityIdentifier("addPartField")
    }

    private func commitNewPart() {
        model.addPart(label: newPart)
        newPart = ""
    }

    // MARK: Planner fallback note

    /// An honest, quiet banner when Crumb wanted its AI planner but built a simple plan instead
    /// (older device, Apple Intelligence off, offline). Parallel to the curator's fallback note.
    private func plannerNote(_ note: String) -> some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(CrumbColor.ink3)
                .accessibilityHidden(true)
            Text(note)
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(CrumbColor.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plannerFallbackNote")
    }

    // MARK: Scan status

    @ViewBuilder
    private var scanRow: some View {
        switch model.loadState {
        case .idle:
            HStack(spacing: CrumbMetrics.Space.s) {
                Image(systemName: "sparkles")
                    .foregroundStyle(CrumbColor.ochre)
                Text("Happy with the plan? I'll go find the pieces.")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                Spacer(minLength: 0)
            }
            .padding(CrumbMetrics.Space.m)
            .accessibilityElement(children: .combine)

        case .loading:
            HStack(spacing: CrumbMetrics.Space.m) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning shops for the right pieces…")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                Spacer(minLength: 0)
            }
            .padding(CrumbMetrics.Space.m)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning shops")

        case .failed:
            failedRow

        case .loaded:
            HStack(spacing: CrumbMetrics.Space.s) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CrumbColor.pine)
                Text("^[\(model.candidates.count) pick](inflect: true) ready across the shops")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                Spacer(minLength: 0)
            }
            .padding(CrumbMetrics.Space.m)
            .accessibilityElement(children: .combine)
        }
    }

    private var failedRow: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(CrumbColor.ochre)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't reach the shops")
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink)
                Text("Check your connection and try again.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
            }
            Spacer(minLength: 0)
            Button("Retry") { model.retryLoad() }
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.pine)
                .accessibilityIdentifier("retryButton")
        }
        .padding(CrumbMetrics.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Couldn't reach the shops. Retry.")
    }

    // MARK: CTA

    private func curateCTA(accent: Color) -> some View {
        Button {
            model.startCurating()
        } label: {
            HStack {
                Spacer()
                Text(model.isScanning ? "Gathering picks…" : "Curate my kit")
                    .font(CrumbType.headline)
                Image(systemName: "rectangle.stack")
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(CrumbMetrics.Space.l)
            .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .crumbShadow()
        }
        .buttonStyle(.plain)
        .disabled(model.isScanning || model.draftParts.isEmpty)
        .opacity(model.isScanning || model.draftParts.isEmpty ? 0.6 : 1)
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.bottom, CrumbMetrics.Space.m)
        .accessibilityIdentifier("curateButton")
    }
}
