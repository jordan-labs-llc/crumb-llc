import SwiftUI
import CrumbKit

/// The Plan screen: the curator's serif note, the parts list, a "scanning shops"
/// affordance while candidates load, and the "Curate my kit" CTA.
struct PlanView: View {
    @Environment(AppModel.self) private var model

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

                partsList(for: task)

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

    private func partsList(for task: ShoppingTask) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Text("The plan")
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)

            ForEach(Array(task.plan.enumerated()), id: \.offset) { _, part in
                HStack(spacing: CrumbMetrics.Space.m) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(CrumbColor.pine)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(part)
                        .font(CrumbType.body)
                        .foregroundStyle(CrumbColor.ink)
                    Spacer(minLength: 0)
                }
            }
        }
        .crumbCard()
    }

    @ViewBuilder
    private var scanRow: some View {
        if model.isScanning {
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
        } else {
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
        .disabled(model.isScanning || model.candidates.isEmpty)
        .opacity(model.isScanning || model.candidates.isEmpty ? 0.6 : 1)
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.bottom, CrumbMetrics.Space.m)
        .accessibilityIdentifier("curateButton")
    }
}
