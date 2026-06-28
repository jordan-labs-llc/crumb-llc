import SwiftUI
import CrumbKit

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
            case .intro: return "So Crumb curates for you, not the average shopper."
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
        .accessibilityIdentifier("OnboardingScreen")
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            HStack(spacing: CrumbMetrics.Space.xs) {
                Image(systemName: "leaf.circle.fill")
                    .foregroundStyle(CrumbColor.pine)
                    .font(.title3)
                    .accessibilityHidden(true)
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
