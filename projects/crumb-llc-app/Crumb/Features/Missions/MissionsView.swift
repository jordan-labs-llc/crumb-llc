import SwiftUI
import CrumbKit
import CrumbArt

/// Home / task entry. A short curator greeting and the **free-text mission composer** — hand
/// Crumb any goal in your own words and the on-device planner decomposes it into a plan. The
/// three seed missions are gone as on-screen cards; the composer (with example + recent prompts)
/// is the only entry now.
struct MissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingSiriDemo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                greeting
                MissionComposer()
                siriHint
            }
            .padding(.horizontal, CrumbMetrics.Space.xl)
            .padding(.vertical, CrumbMetrics.Space.l)
        }
        .accessibilityIdentifier("MissionsScreen")
        .sheet(isPresented: $isShowingSiriDemo) {
            SiriHandoffView()
                .crumbCompactSheet()
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Text("What are we shopping for?")
                .font(CrumbType.display)
                .foregroundStyle(CrumbColor.ink)
            Text("Hand me any goal in your own words. I'll break it into a plan and bring you a kit.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, CrumbMetrics.Space.s)
    }

    private var siriHint: some View {
        Button {
            isShowingSiriDemo = true
        } label: {
            HStack(spacing: CrumbMetrics.Space.m) {
                Image(systemName: "sparkles")
                    .foregroundStyle(CrumbColor.ochre)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask with Siri")
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                    Text("\u{201C}Hey Siri, ask Crumb to set up my pour-over corner\u{201D}")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(CrumbColor.ink3)
            }
            .crumbCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows how the Siri shortcut routes into Crumb")
    }
}

/// The free-text composer: a text box, a "Plan it" CTA with a thinking state, a graceful
/// decline message for non-shopping goals, and quick-tap example + recent prompts.
struct MissionComposer: View {
    @Environment(AppModel.self) private var model

    @State private var goal: String = MissionComposer.seededGoal
    @FocusState private var focused: Bool

    /// Curated starting prompts — these double as the deterministic seed-mission triggers, so
    /// the live mock resolves them to a full deck on device or sim.
    private static let examples = [
        "Set up my pour-over corner",
        "Pack me for a rainy weekend hike",
        "Make my desk feel calm",
        "Cozy reading nook",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            RecipientPicker()
            composerField
            ctaRow

            if let decline = model.planDecline {
                declineRow(decline)
            }

            promptSection(title: "Try one of these", prompts: Self.examples, icon: "wand.and.stars")

            if !model.recentGoals.isEmpty {
                promptSection(title: "Recent", prompts: model.recentGoals, icon: "clock.arrow.circlepath")
            }
        }
    }

    // MARK: Field

    private var composerField: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            TextField(
                "Set up my pour-over corner…",
                text: $goal,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(CrumbType.body)
            .foregroundStyle(CrumbColor.ink)
            .lineLimit(2...5)
            .focused($focused)
            .submitLabel(.go)
            .onSubmit(plan)
            #if os(iOS)
            .textInputAutocapitalization(.sentences)
            #endif
            .accessibilityIdentifier("composerField")
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous)
                .strokeBorder(focused ? CrumbColor.pine : CrumbColor.line, lineWidth: focused ? 1.5 : 1)
        )
        .crumbShadow()
    }

    // MARK: CTA / thinking state

    private var ctaRow: some View {
        Button(action: plan) {
            HStack(spacing: CrumbMetrics.Space.s) {
                Spacer()
                if model.isPlanning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Planning your mission…")
                        .font(CrumbType.headline)
                } else {
                    Image(systemName: "sparkles")
                    Text("Plan it")
                        .font(CrumbType.headline)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(CrumbMetrics.Space.l)
            .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
            .crumbShadow()
        }
        .buttonStyle(.plain)
        .disabled(goal.trimmed.isEmpty || model.isPlanning)
        .opacity(goal.trimmed.isEmpty || model.isPlanning ? 0.6 : 1)
        .accessibilityIdentifier("planButton")
    }

    private func declineRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(CrumbColor.ochre)
                .accessibilityHidden(true)
            Text(text)
                .font(CrumbType.curatorCaption)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.pineSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composerDecline")
    }

    // MARK: Prompt chips

    private func promptSection(title: String, prompts: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Label(title, systemImage: icon)
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
            FlexibleWrap(spacing: CrumbMetrics.Space.s) {
                ForEach(prompts, id: \.self) { prompt in
                    PromptChip(text: prompt) { start(prompt) }
                }
            }
        }
        .padding(.top, CrumbMetrics.Space.xs)
    }

    // MARK: Actions

    private func plan() {
        let trimmed = goal.trimmed
        guard !trimmed.isEmpty, !model.isPlanning else { return }
        focused = false
        model.planMission(goal: trimmed, for: model.composerRecipient)
    }

    /// Tapping an example/recent fills the field (so the choice is visible) and plans it for the
    /// currently chosen recipient (You by default).
    private func start(_ prompt: String) {
        guard !model.isPlanning else { return }
        goal = prompt
        focused = false
        model.planMission(goal: prompt, for: model.composerRecipient)
    }

    /// In DEBUG screenshot mode, pre-fill the field from `CRUMB_GOAL` so the composer can be
    /// captured "mid-typing" without `simctl` being able to inject keystrokes.
    private static var seededGoal: String {
        #if DEBUG
        let mode = ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"]
        if mode == "composer" || mode == "composer-gift" {
            return ProcessInfo.processInfo.environment["CRUMB_GOAL"] ?? ""
        }
        #endif
        return ""
    }
}

/// A pill that submits its prompt on tap — the example / recent quick-starts.
private struct PromptChip: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(CrumbType.pill)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(1)
                .padding(.horizontal, CrumbMetrics.Space.m)
                .padding(.vertical, CrumbMetrics.Space.s)
                .background(CrumbColor.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(CrumbColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plan: \(text)")
    }
}
