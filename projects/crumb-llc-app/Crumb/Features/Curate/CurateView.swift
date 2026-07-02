import SwiftUI
import CrumbKit
import CrumbArt

/// **The signature screen.** A swipeable deck of product proposals over the pinned
/// ``KitTray``. Swipe right (or tap "Add") to drop an item into the kit; swipe left
/// (or tap "Skip") to pass. Honors `accessibilityReduceMotion` and offers buttons as an
/// accessible, pointer-friendly alternative to dragging.
struct CurateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragOffset: CGSize = .zero
    @State private var decisionEdge: Edge = .trailing

    private let threshold: CGFloat = 120

    var body: some View {
        VStack(spacing: CrumbMetrics.Space.l) {
            if model.isReworking {
                activityBanner("Reworking the deck…", id: "reworkingBanner")
            } else if model.isRecurating {
                activityBanner("Re-reading your taste…", id: "recuratingBanner")
            } else if model.isScanning {
                // Streaming: raw picks are on screen while the gather finishes and the curator ranks
                // + voices them (they settle in place when done).
                activityBanner("Curating your picks…", id: "gatheringBanner")
            }
            if let note = model.refinementFallbackNote ?? model.curatorFallbackNote {
                fallbackNote(note)
            }
            if model.deck.isEmpty {
                emptyState
            } else {
                deck
                controls
            }
        }
        .padding(.horizontal, CrumbMetrics.Space.xl)
        .padding(.top, CrumbMetrics.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The refinement bar sits ABOVE the KitTray: it's the inner bottom inset (applied first),
        // so the later KitTray inset reserves the very bottom and the bar stacks just above it.
        .safeAreaInset(edge: .bottom) {
            RefinementBar()
                .padding(.bottom, CrumbMetrics.Space.s)
        }
        .safeAreaInset(edge: .bottom) {
            KitTray(items: model.kit, isSingleProduct: model.isSingleProductMission) { model.openCart() }
                .padding(.horizontal, CrumbMetrics.Space.l)
                .padding(.bottom, CrumbMetrics.Space.s)
        }
        // Mark the screen as an accessibility *container* so its id names the container, not every
        // child. On a plain VStack root `.accessibilityIdentifier` propagates onto every descendant
        // (addButton/skipButton/cards all reported "CurateScreen"); `.contain` keeps each child's
        // own id queryable — same behavior a ScrollView root gets for free. (#24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CurateScreen")
    }

    // MARK: Deck

    private var deck: some View {
        ZStack {
            ForEach(visibleCards.reversed()) { entry in
                cardView(for: entry)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 460)
    }

    private struct DeckEntry: Identifiable {
        let product: Product
        let depth: Int   // 0 == top
        var id: String { product.id }
    }

    private var visibleCards: [DeckEntry] {
        model.deck.prefix(3).enumerated().map { DeckEntry(product: $1, depth: $0) }
    }

    @ViewBuilder
    private func cardView(for entry: DeckEntry) -> some View {
        let isTop = entry.depth == 0
        ProductCard(product: entry.product, isInKit: model.isInKit(entry.product))
            .scaleEffect(isTop ? 1 : 1 - CGFloat(entry.depth) * 0.04)
            .offset(y: isTop ? 0 : CGFloat(entry.depth) * 14)
            .offset(isTop ? dragOffset : .zero)
            .rotationEffect(isTop ? rotation : .zero)
            .opacity(isTop ? 1 : 0.85)
            .overlay(alignment: .top) {
                if isTop { decisionStamp }
            }
            .allowsHitTesting(isTop)
            .gesture(isTop ? dragGesture(for: entry.product) : nil)
            .transition(.move(edge: decisionEdge).combined(with: .opacity))
            .zIndex(isTop ? 1 : 0)
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                Button(addActionTitle) { decide(accept: true, product: entry.product) }
                Button("Skip") { decide(accept: false, product: entry.product) }
            }
    }

    private var rotation: Angle {
        guard !reduceMotion else { return .zero }
        return .degrees(Double(dragOffset.width / 18))
    }

    /// A "Add" / "Skip" stamp that fades in as the user drags.
    @ViewBuilder
    private var decisionStamp: some View {
        let accepting = dragOffset.width > 0
        let strength = min(1, abs(dragOffset.width) / threshold)
        if strength > 0.05 {
            Text(accepting ? "ADD" : "SKIP")
                .font(CrumbType.title2)
                .foregroundStyle(.white)
                .padding(.horizontal, CrumbMetrics.Space.l)
                .padding(.vertical, CrumbMetrics.Space.s)
                .background(accepting ? CrumbColor.pine : CrumbColor.ink2, in: Capsule())
                .opacity(strength)
                .padding(.top, CrumbMetrics.Space.xl)
                .accessibilityHidden(true)
        }
    }

    private func dragGesture(for product: Product) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                if value.translation.width > threshold {
                    decide(accept: true, product: product)
                } else if value.translation.width < -threshold {
                    decide(accept: false, product: product)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func decide(accept: Bool, product: Product) {
        decisionEdge = accept ? .trailing : .leading
        dragOffset = .zero
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) {
            if accept {
                model.accept(product)
            } else {
                model.skip(product)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: CrumbMetrics.Space.xl) {
            decisionButton(
                title: "Skip",
                systemImage: "xmark",
                tint: CrumbColor.ink2,
                accept: false
            )
            decisionButton(
                title: addActionTitle,
                systemImage: "checkmark",
                tint: CrumbColor.pine,
                accept: true
            )
        }
        .disabled(model.deck.isEmpty)
    }

    /// "Add to shortlist" for a direct single-product search (the deck is options to compare),
    /// "Add to kit" for a multi-part mission (#56).
    private var addActionTitle: String {
        model.isSingleProductMission ? "Add to shortlist" : "Add to kit"
    }

    private func decisionButton(
        title: String,
        systemImage: String,
        tint: Color,
        accept: Bool
    ) -> some View {
        Button {
            guard let top = model.deck.first else { return }
            decide(accept: accept, product: top)
        } label: {
            Label(title, systemImage: systemImage)
                .font(CrumbType.headline)
                .foregroundStyle(accept ? .white : CrumbColor.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CrumbMetrics.Space.m)
                .background(
                    accept ? AnyShapeStyle(tint) : AnyShapeStyle(CrumbColor.raised),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(CrumbColor.line, lineWidth: accept ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accept ? "addButton" : "skipButton")
    }

    /// A quiet shimmer banner shown while the deck is being re-worked live — by a taste edit
    /// ("Re-reading your taste…") or a conversational refinement ("Reworking the deck…") — so the
    /// change reads as a response to what the user just did. Shared by both states.
    private func activityBanner(_ message: String, id: String) -> some View {
        HStack(spacing: CrumbMetrics.Space.s) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.m)
        .background(CrumbColor.pineSoft, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier(id)
    }

    // MARK: Curator fallback note

    /// An honest, quiet banner shown when Crumb wanted its AI curator but fell back to the
    /// deterministic voice (older device, Apple Intelligence off, quota spent, or offline).
    private func fallbackNote(_ note: String) -> some View {
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
        .accessibilityIdentifier("curatorFallbackNote")
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: CrumbMetrics.Space.l) {
            Spacer()
            CrumbEmptyArt(variant: model.kit.isEmpty ? .nothingYet : .kitReady)
            Text(model.kit.isEmpty ? "Nothing added yet" : "That's a kit.")
                .font(CrumbType.title)
                .foregroundStyle(CrumbColor.ink)
            Text(model.kit.isEmpty
                ? "You skipped everything — find more when you're ready."
                : "^[\(model.kit.count) item](inflect: true) ready to review.")
                .font(CrumbType.curator)
                .foregroundStyle(CrumbColor.ink2)
                .multilineTextAlignment(.center)

            if model.kit.isEmpty {
                Button("Find more") { model.reshuffleDeck() }
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.pine)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
