import SwiftUI
import CrumbKit
import CrumbArt

/// First-run taste capture. A short, **skippable** flow that builds the user's
/// ``TasteProfile`` before they reach Missions — the personalization Crumb's curator ranks
/// and speaks against. Shown only when no profile has been persisted (see ``Route/onboarding``);
/// Skip or Start both persist a profile so it never reappears.
///
/// The draft starts from ``SeedData/defaultTasteProfile`` so every field has a sensible
/// default the user can keep, tweak, or replace — including via the AI "describe your taste"
/// box on the first step.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = SeedData.defaultTasteProfile
    @State private var step = 0

    private let steps = Step.allCases

    private enum Step: Int, CaseIterable {
        case intro, vibe, leanings, budget

        var title: String {
            switch self {
            case .intro: return "Let's get your taste"
            case .vibe: return "What's your vibe?"
            case .leanings: return "Any leanings?"
            case .budget: return "Budget & signature"
            }
        }

        var subtitle: String {
            switch self {
            case .intro: return "Start with what you're shopping for — or set your taste first."
            case .vibe: return "A few words for the feel you're after."
            case .leanings: return "The trade-offs and preferences you keep coming back to."
            case .budget: return "How freely you spend — and your taste in a line."
            }
        }
    }

    private var current: Step { steps[step] }
    private var isLast: Bool { step == steps.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                    heading
                    stepContent
                    Spacer(minLength: CrumbMetrics.Space.l)
                }
                .padding(.horizontal, CrumbMetrics.Space.xl)
                .padding(.top, CrumbMetrics.Space.m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom) { navBar }
        .animation(.easeInOut(duration: 0.2), value: step)
        // Mark the screen as an accessibility *container* so its id names the container, not every
        // child. On a plain VStack root `.accessibilityIdentifier` propagates onto every descendant —
        // Skip/Next/title/scroll view all reported "OnboardingScreen", so `onboardingSkip` /
        // `onboardingNext` weren't queryable and UI tests fell back to the "Skip" label. `.contain`
        // keeps each child's own id queryable (same fix as CurateView, #24). (#61)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("OnboardingScreen")
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            HStack(spacing: CrumbMetrics.Space.xs) {
                CrumbBadge(size: 26)
                Text("Crumb")
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
            }
            Spacer()
            Button("Skip") { model.skipOnboarding() }
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink2)
                .accessibilityIdentifier("onboardingSkip")
        }
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.vertical, CrumbMetrics.Space.m)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            progressDots
            Text(current.title)
                .font(CrumbType.display)
                .foregroundStyle(CrumbColor.ink)
            Text(current.subtitle)
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressDots: some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? CrumbColor.pine : CrumbColor.line)
                    .frame(width: index == step ? 22 : 7, height: 7)
            }
        }
        .accessibilityLabel("Step \(step + 1) of \(steps.count)")
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch current {
        case .intro:
            CrumbHeroArt()
                .frame(height: 120)
                .padding(.bottom, CrumbMetrics.Space.s)
            // Let the goal lead: a new user who just wants to shop can start here and pick up
            // their taste as they go (issue #28). The taste-first path stays right below.
            GoalFirstCard()
            orDivider
            DescribeYourselfCard(draft: $draft)
        case .vibe:
            EditableChipSection(
                title: "Vibe",
                tint: CrumbColor.pine,
                items: $draft.vibe,
                suggestions: TasteVocabulary.vibe
            )
        case .leanings:
            EditableChipSection(
                title: "Leanings",
                tint: CrumbColor.ink2,
                items: $draft.leanings,
                suggestions: TasteVocabulary.leanings
            )
        case .budget:
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xl) {
                BudgetComfortSlider(value: $draft.budgetComfort)
                SignatureEditor(text: $draft.signatureLine)
            }
        }
    }

    /// A quiet "or" separator between the goal-first fast path and the taste-first editors.
    private var orDivider: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            Rectangle().fill(CrumbColor.line).frame(height: 1)
            Text("or set your taste")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink3)
                .fixedSize()
            Rectangle().fill(CrumbColor.line).frame(height: 1)
        }
        .padding(.vertical, CrumbMetrics.Space.xs)
        .accessibilityHidden(true)
    }

    // MARK: Nav

    private var navBar: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            if step > 0 {
                Button {
                    step -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .frame(width: 50, height: 50)
                        .background(CrumbColor.raised, in: Circle())
                        .overlay(Circle().strokeBorder(CrumbColor.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Button(action: advance) {
                HStack {
                    Spacer()
                    Text(isLast ? "Start curating" : "Next")
                        .font(CrumbType.headline)
                    Image(systemName: isLast ? "sparkles" : "arrow.right")
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(CrumbMetrics.Space.l)
                .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
                .crumbShadow()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboardingNext")
        }
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.bottom, CrumbMetrics.Space.m)
    }

    private func advance() {
        if isLast {
            model.completeOnboarding(with: draft.normalized)
        } else {
            step += 1
        }
    }
}

// MARK: - Goal-first fast path

/// The "let the goal lead" card on the first onboarding step: a new user who just wants to shop
/// types what they're after and goes, skipping taste capture. The goal seeds an initial taste and
/// plans straight into the deck (``AppModel/startFromGoal(_:)``); the full taste flow stays right
/// below for anyone who'd rather set it up first. See issue #28.
struct GoalFirstCard: View {
    @Environment(AppModel.self) private var model

    @State private var text = GoalFirstCard.seededText
    @FocusState private var focused: Bool

    private var canStart: Bool { !text.trimmed.isEmpty && !model.isPlanning }

    var body: some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.s) {
            Label("What are you shopping for?", systemImage: "bag")
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.ink)

            Text("Tell me what you need and I'll start curating — I'll pick up your taste as we go.")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Jasmine tea for Maya's birthday", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CrumbType.body)
                .foregroundStyle(CrumbColor.ink)
                .lineLimit(1...3)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(start)
                .padding(CrumbMetrics.Space.m)
                .background(CrumbColor.paper, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                        .strokeBorder(focused ? CrumbColor.pine : CrumbColor.line, lineWidth: focused ? 1.5 : 1)
                )
                .accessibilityIdentifier("goalFirstField")

            Button(action: start) {
                HStack(spacing: CrumbMetrics.Space.s) {
                    if model.isPlanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(model.isPlanning ? "Curating…" : "Start shopping")
                        .font(CrumbType.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CrumbMetrics.Space.m)
                .background(canStart ? CrumbColor.pine : CrumbColor.ink3, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
            .accessibilityIdentifier("goalFirstStart")
        }
        .crumbCard()
    }

    private func start() {
        let goal = text.trimmed
        guard !goal.isEmpty, !model.isPlanning else { return }
        focused = false
        model.startFromGoal(goal)
    }

    /// In DEBUG screenshot mode, pre-fill the goal from `CRUMB_GOAL` so the goal-first card can be
    /// captured populated — `simctl` can inject neither taps nor keystrokes.
    private static var seededText: String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRUMB_SCREENSHOT"] == "onboarding" {
            return ProcessInfo.processInfo.environment["CRUMB_GOAL"] ?? ""
        }
        #endif
        return ""
    }
}
