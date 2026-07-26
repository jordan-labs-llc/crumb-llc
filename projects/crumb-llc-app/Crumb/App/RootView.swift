import SwiftUI
import CrumbKit
import CrumbArt

/// The app shell: a quiet paper board with a slim header, the routed screen, and the
/// taste-profile / checkout-handoff overlays. Switches on `AppModel.route`.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingSiriDemo = false

    var body: some View {
        @Bindable var model = model

        ZStack {
            CrumbColor.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                // Onboarding is a self-contained first-run flow with its own header and skip,
                // so the app navigation header stays out of its way.
                if model.route != .onboarding {
                    AppHeader {
                        isShowingSiriDemo = true
                    }
                }
                routedContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Give each route its own identity and an OPAQUE paper backing, then swap with an
                    // asymmetric transition: the outgoing screen is removed instantly (`.identity`)
                    // while the incoming fades in (`.opacity`). The old default — a symmetric opacity
                    // crossfade of two transparent screens — left both visible mid-transition, so the
                    // Plan title collided with the ghosted composer ("What are we shopping for?") and
                    // Missions content lingered behind the plan. Removing the outgoing screen up front
                    // means the two screens are never on screen at once. (#66)
                    .id(model.route)
                    .background(CrumbColor.paper)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            // macOS / visionOS get a wider windowed layout; iOS is the phone column.
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.route)
        // Crumb is a light-only app, and this is the line that makes that true rather than
        // accidental. Every `CrumbColor` token is a fixed sRGB value chosen for warm paper on a
        // greige board, so the palette does not adapt — but the system materials layered over it
        // (the response dock, the cart and onboarding bars) *do*. Under a dark appearance that
        // split rendered a grey band beneath light content and dropped the dock placeholder
        // (`ink3`) to near-illegible contrast. Pinning the scheme keeps the tokens and the
        // materials describing the same surface. Adding real dark support means giving
        // `CrumbColor` (and `CrumbMetrics`' ink-tinted shadows) dark variants first; until then
        // this stays.
        .preferredColorScheme(.light)
        // Load every descendant `AsyncImage` (deck cards, kit-tray + cart thumbnails) through one
        // cache-backed URLSession so re-showing an already-seen product photo — swiping the deck back
        // and forth — is served from the URLCache instead of re-downloaded (#43 item 1).
        .asyncImageURLSession(CrumbImageCache.session)
        // Wake the (scale-to-zero) broker while the user gets oriented, so the first live
        // mission usually lands warm. No-op on the mock.
        .task { await model.warmUpCatalog() }
        #if DEBUG
        // Headless screenshot routing: deal a curate deck without taps (see `CrumbApp`).
        .task {
            let env = ProcessInfo.processInfo.environment
            let mission = env["CRUMB_MISSION"] ?? "coffee"
            switch env["CRUMB_SCREENSHOT"] {
            case "curate", "conversation-product":
                await model.presentCurateForScreenshot(missionID: mission)
            case "cart": await model.presentCartForScreenshot(missionID: mission)
            case "sandbox-contact": await model.presentSandboxCheckoutForScreenshot(missionID: mission, stage: "contact")
            case "sandbox-review": await model.presentSandboxCheckoutForScreenshot(missionID: mission, stage: "review")
            case "sandbox-completed": await model.presentSandboxCheckoutForScreenshot(missionID: mission, stage: "completed")
            case "kit": await model.presentFullKitForScreenshot(missionID: mission)
            case "plan", "conversation-plan": model.presentPlanForScreenshot(missionID: mission)
            case "refine":
                // Deal a deck then run a canned refinement so the reworked deck + bar render.
                let refinement = env["CRUMB_REFINE"] ?? "make it cheaper"
                await model.presentRefinedDeckForScreenshot(missionID: mission, refinement: refinement)
            // History: the store is seeded (or left empty for `history-empty`) in `CrumbApp`.
            case "history", "history-empty": model.presentHistoryForScreenshot()
            case "history-detail": model.presentHistoryDetailForScreenshot()
            // People & gift flows: the recipient store is seeded (or empty for `people-empty`).
            case "people", "people-empty": model.presentPeopleForScreenshot()
            case "composer-gift": model.presentComposerGiftForScreenshot()
            case "gift": await model.presentGiftCurateForScreenshot(missionID: mission)
            case "history-gift": model.presentGiftHistoryForScreenshot()
            // "composer" (and anything else) lands on the new-mission conversation dock.
            default: break
            }
        }
        #endif
        .sheet(isPresented: $isShowingSiriDemo) {
            SiriHandoffView()
                .crumbCompactSheet()
        }
        .sheet(isPresented: $model.isShowingTasteProfile) {
            TasteProfileView(initial: model.tasteProfile)
                .crumbExpandableSheet()
        }
        .sheet(item: $model.handoff) { handoff in
            CheckoutHandoffView(handoff: handoff)
                .crumbCompactSheet()
        }
        .sheet(item: $model.checkoutWorkflow) { workflow in
            CheckoutWorkflowView(workflow: workflow)
                .crumbExpandableSheet()
        }
        .sheet(item: $model.reshopEntry) { entry in
            HistoryReshopView(entry: entry)
                .crumbCompactSheet()
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch model.route {
        case .onboarding: OnboardingView()
        case .missions: MissionsView()
        case .missionThread:
            MissionThreadView()
                // Phase changes keep the workspace mounted; changing to a different mission gets a
                // fresh set of view-local focus, drag, scroll, and composer state.
                .id(model.activeThreadID ?? "no-active-thread")
        case .cart: CartView()
        case .history: HistoryView()
        case .historyDetail: HistoryDetailView()
        case .people: PeopleView()
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

/// Slim top bar: back, brand, and one menu for secondary destinations. Keeping History, People,
/// taste, and Siri behind one labeled affordance avoids a row of icon-only pseudo-tabs.
struct AppHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onShowSiri: () -> Void

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
                .accessibilityIdentifier("backButton")
                .transition(.opacity)
            }

            HStack(spacing: CrumbMetrics.Space.xs) {
                CrumbBadge(size: 26)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Crumb")
                        .font(CrumbType.title2)
                        .foregroundStyle(CrumbColor.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer()

            Menu {
                Button {
                    model.openHistory()
                } label: {
                    Label("Mission history", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("historyButton")

                Button {
                    model.openPeople()
                } label: {
                    Label("People you shop for", systemImage: "person.2")
                }
                .accessibilityIdentifier("peopleButton")

                Button {
                    model.isShowingTasteProfile = true
                } label: {
                    Label("Taste profile", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("tasteProfileButton")

                Button(action: onShowSiri) {
                    Label("Ask with Siri", systemImage: "sparkles")
                }
                .accessibilityIdentifier("siriButton")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .font(CrumbType.captionStrong)
                    .foregroundStyle(CrumbColor.ink2)
                    .padding(.horizontal, CrumbMetrics.Space.s)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options")
            .accessibilityHint("Shows mission history, people, taste profile, and Siri")
            .accessibilityIdentifier("moreMenu")
        }
        // Navigation chrome must remain recognizable at the largest accessibility sizes. Mission
        // content and the response dock continue to use the user's full setting; only this fixed-
        // height icon row is capped so glyphs do not overlap or clip out of their hit targets.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.vertical, CrumbMetrics.Space.m)
        .accessibilityElement(children: .contain)
    }
}
