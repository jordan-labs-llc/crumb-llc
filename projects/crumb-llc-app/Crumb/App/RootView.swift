import SwiftUI
import CrumbKit
import CrumbArt

/// The app shell: a quiet paper board with a slim header, the routed screen, and the
/// taste-profile / checkout-handoff overlays. Switches on `AppModel.route`.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        ZStack {
            CrumbColor.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                // Onboarding is a self-contained first-run flow with its own header and skip,
                // so the app chrome (back / taste button) stays out of its way.
                if model.route != .onboarding {
                    AppHeader()
                }
                routedContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // macOS / visionOS get a wider windowed layout; iOS is the phone column.
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.route)
        // Wake the (scale-to-zero) broker while the user gets oriented, so the first live
        // mission usually lands warm. No-op on the mock.
        .task { await model.warmUpCatalog() }
        #if DEBUG
        // Headless screenshot routing: deal a curate deck without taps (see `CrumbApp`).
        .task {
            let env = ProcessInfo.processInfo.environment
            let mission = env["CRUMB_MISSION"] ?? "coffee"
            switch env["CRUMB_SCREENSHOT"] {
            case "curate": await model.presentCurateForScreenshot(missionID: mission)
            case "kit": await model.presentFullKitForScreenshot(missionID: mission)
            default: break
            }
        }
        #endif
        .sheet(isPresented: $model.isShowingTasteProfile) {
            TasteProfileView(initial: model.tasteProfile)
                .crumbExpandableSheet()
        }
        .sheet(item: $model.handoff) { handoff in
            CheckoutHandoffView(handoff: handoff)
                .crumbCompactSheet()
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch model.route {
        case .onboarding: OnboardingView()
        case .missions: MissionsView()
        case .plan: PlanView()
        case .curate: CurateView()
        case .cart: CartView()
        }
    }

    private var contentMaxWidth: CGFloat {
        #if os(macOS) || os(visionOS)
        return 600
        #else
        return .infinity
        #endif
    }
}

/// Slim top bar: a back affordance (when not at the root), the wordmark, and a taste
/// profile button.
struct AppHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: CrumbMetrics.Space.m) {
            if model.route != .missions {
                Button(action: model.back) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .frame(width: 30, height: 30)
                        .background(CrumbColor.raised, in: Circle())
                        .overlay(Circle().strokeBorder(CrumbColor.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .transition(.opacity)
            }

            HStack(spacing: CrumbMetrics.Space.xs) {
                CrumbBadge(size: 26)
                Text("Crumb")
                    .font(CrumbType.title2)
                    .foregroundStyle(CrumbColor.ink)
            }

            Spacer()

            Button {
                model.isShowingTasteProfile = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(CrumbColor.ink2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your taste profile")
        }
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.vertical, CrumbMetrics.Space.m)
        .accessibilityElement(children: .contain)
    }
}
