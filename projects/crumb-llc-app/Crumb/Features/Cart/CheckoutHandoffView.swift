import SwiftUI
import CrumbKit

/// The per-shop checkout handoff sheet. Shows the shop's items and a button that opens
/// the merchant's own secure checkout via the UCP `continue_url` (or the merchant
/// storefront fallback). When no handoff target exists, it says so plainly rather than
/// presenting a dead button.
struct CheckoutHandoffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    let handoff: AppModel.Handoff

    private var subtotal: Decimal {
        handoff.items.reduce(0) { $0 + $1.variant.price }
    }

    var body: some View {
        BottomSheet(
            title: "Continue to \(handoff.shop.name)",
            subtitle: "Secure checkout, handled by the shop",
            onClose: { model.handoff = nil }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                ForEach(handoff.items) { item in
                    HStack {
                        Text(TitleHygiene.display(for: item.product.name))
                            .font(CrumbType.body)
                            .foregroundStyle(CrumbColor.ink)
                            .lineLimit(2)
                            .accessibilityLabel(item.product.name)
                        Spacer()
                        Text(item.variant.price, format: .currency(code: "USD"))
                            .font(CrumbType.body)
                            .foregroundStyle(CrumbColor.ink2)
                            .monospacedDigit()
                    }
                }

                Divider().overlay(CrumbColor.line)

                HStack {
                    Text("Subtotal")
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                    Spacer()
                    Text(subtotal, format: .currency(code: "USD"))
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                        .monospacedDigit()
                }

                if let url = handoff.url {
                    Button {
                        // Opening a real checkout link is the honest "handed off" signal — flip
                        // this session's history entry's outcome flag (a no-link handoff doesn't).
                        model.recordHandoffFollowed()
                        openURL(url)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "lock.fill")
                            Text("Continue to \(handoff.shop.name)")
                                .font(CrumbType.headline)
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(CrumbMetrics.Space.l)
                        .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("handoffContinue")

                    Text("This hands off to \(handoff.shop.name)'s own secure checkout. "
                        + "You'll confirm payment with the merchant — Crumb never sees your card.")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    noHandoff
                }
            }
        }
    }

    /// Shown when no handoff target could be resolved for this shop — honest about the
    /// gap instead of a button that does nothing.
    private var noHandoff: some View {
        HStack(alignment: .top, spacing: CrumbMetrics.Space.s) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(CrumbColor.ochre)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No checkout link yet")
                    .font(CrumbType.headline)
                    .foregroundStyle(CrumbColor.ink)
                Text("\(handoff.shop.name) hasn't shared a checkout link for these items. "
                    + "Try again later, or search for them on the shop's site.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(CrumbMetrics.Space.l)
        .background(CrumbColor.raised, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("handoffUnavailable")
    }
}

/// Progress and recovery for a multi-merchant cart. Every merchant is represented even when one
/// cannot prepare a checkout, so partial success is explicit and independently actionable.
struct CheckoutWorkflowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    let workflow: AppModel.CheckoutWorkflow

    var body: some View {
        BottomSheet(
            title: workflow.merchants.count == 1 ? "Your checkout" : "Your checkouts",
            subtitle: subtitle,
            onClose: { model.closeCheckoutWorkflow() }
        ) {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.l) {
                if workflow.merchants.count > 1 {
                    Label(
                        "Each shop is a separate order. Complete each prepared checkout with that merchant.",
                        systemImage: "square.stack.3d.up"
                    )
                    .font(CrumbType.callout)
                    .foregroundStyle(CrumbColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("multiMerchantDisclosure")
                }

                ForEach(workflow.merchants) { merchant in
                    merchantCard(merchant)
                }

                Text("Prices, availability, shipping, taxes, discounts, and the final total are confirmed by each merchant.")
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("merchantAuthoritativeNote")
            }
            // Container, not clobber: on a plain VStack the id propagates onto every descendant,
            // hiding multiMerchantDisclosure / merchantAuthoritativeNote from UI tests (#61).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CheckoutWorkflow")
        }
    }

    private var subtitle: String {
        if workflow.isPreparing { return "Preparing secure merchant checkouts…" }
        if workflow.completedCount > 0 {
            return "\(workflow.completedCount) completed · \(workflow.preparedCount) ready"
        }
        return "\(workflow.preparedCount) of \(workflow.merchants.count) ready"
    }

    @ViewBuilder
    private func merchantCard(_ merchant: AppModel.MerchantCheckout) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            HStack {
                Image(systemName: "storefront")
                    .foregroundStyle(CrumbColor.pine)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(merchant.shop.name)
                        .font(CrumbType.headline)
                        .foregroundStyle(CrumbColor.ink)
                    Text("^[\(merchant.items.count) item](inflect: true)")
                        .font(CrumbType.caption)
                        .foregroundStyle(CrumbColor.ink3)
                }
                Spacer()
                stateBadge(merchant)
            }

            switch merchant.state {
            case .preparing:
                HStack(spacing: CrumbMetrics.Space.s) {
                    ProgressView()
                    Text("Preparing checkout…")
                        .font(CrumbType.callout)
                        .foregroundStyle(CrumbColor.ink2)
                }
                .accessibilityIdentifier("checkoutPreparing.\(merchant.shop.id)")

            case .prepared(let session):
                if let sandbox = merchant.sandbox {
                    sandboxCheckout(merchant: merchant, session: session, sandbox: sandbox)
                } else {
                if let total = session.total {
                    HStack {
                        Text(total.displayText ?? "Merchant total")
                            .font(CrumbType.callout)
                            .foregroundStyle(CrumbColor.ink2)
                        Spacer()
                        Text(CheckoutCurrency.formatted(minorUnits: total.amount, currency: session.currency))
                            .font(CrumbType.headline)
                            .foregroundStyle(CrumbColor.ink)
                            .monospacedDigit()
                            .accessibilityIdentifier("checkoutTotal.\(merchant.shop.id)")
                    }
                }
                ForEach(Array(session.messages.enumerated()), id: \.offset) { _, message in
                    Label(message.content, systemImage: messageSymbol(message))
                        .font(CrumbType.caption)
                        .foregroundStyle(message.type == .error || message.type == .warning ? CrumbColor.ochre : CrumbColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(message.presentation == .disclosure ? CrumbMetrics.Space.s : 0)
                        .background(
                            message.presentation == .disclosure ? CrumbColor.ochre.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous)
                        )
                }
                legalLinks(session.links)

                if session.status == .requiresEscalation, let url = session.continueURL {
                    Button {
                        model.recordHandoffFollowed()
                        openURL(url)
                    } label: {
                        Label("Continue to \(merchant.shop.name)", systemImage: "arrow.up.right")
                            .font(CrumbType.headline)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                            .padding(.vertical, CrumbMetrics.Space.m)
                            .background(CrumbColor.pine, in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("checkoutContinue.\(merchant.shop.id)")
                } else if session.status == .completed {
                    Label("This merchant reports checkout complete.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(CrumbColor.pine)
                        .accessibilityIdentifier("checkoutCompleted.\(merchant.shop.id)")
                } else if session.status == .canceled {
                    checkoutProblem("This checkout was canceled by the merchant.", systemImage: "xmark.circle")
                        .accessibilityIdentifier("checkoutCanceled.\(merchant.shop.id)")
                } else {
                    checkoutProblem(
                        statusMessage(session.status), systemImage: "clock.badge.questionmark"
                    )
                    .accessibilityIdentifier("checkoutContinueUnavailable.\(merchant.shop.id)")
                }
                }

            case .unsupported(let message, let fallbackURL):
                checkoutProblem(message, systemImage: "cart.badge.questionmark")
                    .accessibilityIdentifier("checkoutUnsupported.\(merchant.shop.id)")
                if let fallbackURL {
                    Button {
                        model.recordHandoffFollowed()
                        openURL(fallbackURL)
                    } label: {
                        Label("Open \(merchant.shop.name) website (not UCP)", systemImage: "safari")
                            .font(CrumbType.headline)
                    }
                    .foregroundStyle(CrumbColor.pine)
                    .accessibilityIdentifier("checkoutFallback.\(merchant.shop.id)")
                    .accessibilityHint("Leaves Crumb for the merchant website; cart contents may not carry over")
                }

            case .failed(let message):
                checkoutProblem(message, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("checkoutFailed.\(merchant.shop.id)")
                Button("Retry \(merchant.shop.name)") {
                    Task { await model.retryCheckout(for: merchant.shop) }
                }
                .font(CrumbType.headline)
                .foregroundStyle(CrumbColor.pine)
                .accessibilityIdentifier("checkoutRetry.\(merchant.shop.id)")
            }
        }
        .crumbCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("merchantCheckout.\(merchant.shop.id)")
    }

    private func checkoutProblem(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(CrumbType.callout)
            .foregroundStyle(CrumbColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func sandboxCheckout(
        merchant: AppModel.MerchantCheckout,
        session: CheckoutSession,
        sandbox: AppModel.SandboxCheckout
    ) -> some View {
        Label("SANDBOX · No real charge", systemImage: "testtube.2")
            .font(CrumbType.headline)
            .foregroundStyle(CrumbColor.ochre)
            .accessibilityIdentifier("sandboxBadge")

        switch sandbox.phase {
        case .contact:
            sandboxContactForm(merchant: merchant, sandbox: sandbox)
        case .updating:
            ProgressView("Updating sandbox checkout…")
                .accessibilityIdentifier("sandboxUpdating")
        case .shipping:
            sandboxReview(merchant: merchant, session: session, sandbox: sandbox, allowsPlacement: false)
        case .review:
            sandboxReview(merchant: merchant, session: session, sandbox: sandbox, allowsPlacement: true)
        case .completing:
            ProgressView("Placing sandbox order…")
                .accessibilityIdentifier("sandboxProcessing")
        case .completed:
            sandboxConfirmation(session: session)
        case .expired:
            checkoutProblem("This sandbox checkout expired. Its buyer details will be discarded.", systemImage: "clock.badge.exclamationmark")
                .accessibilityIdentifier("sandboxExpired")
            Button("Start fresh sandbox checkout") {
                Task { await model.startFreshSandboxCheckout(for: merchant.shop) }
            }
            .accessibilityIdentifier("sandboxStartFresh")
        case .failed(let message):
            checkoutProblem(message, systemImage: "exclamationmark.triangle.fill")
                .accessibilityIdentifier("sandboxFailure")
            Button(message.contains("uncertain") ? "Discard and start fresh sandbox checkout" : "Try sandbox update again") {
                Task {
                    if message.contains("uncertain") { await model.startFreshSandboxCheckout(for: merchant.shop) }
                    else { await model.retrySandboxCheckout(for: merchant.shop) }
                }
            }
            .accessibilityIdentifier("sandboxRetry")
        }
    }

    private func sandboxContactForm(
        merchant: AppModel.MerchantCheckout,
        sandbox: AppModel.SandboxCheckout
    ) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Text("Sandbox contact & shipping")
                .font(CrumbType.headline)
            TextField("First name", text: sandboxBinding(merchant.shop, \.firstName))
                .textContentType(.givenName).accessibilityIdentifier("sandboxFirstName")
            TextField("Last name", text: sandboxBinding(merchant.shop, \.lastName))
                .textContentType(.familyName).accessibilityIdentifier("sandboxLastName")
            TextField("Email", text: sandboxBinding(merchant.shop, \.email))
                .textContentType(.emailAddress).accessibilityIdentifier("sandboxEmail")
            TextField("Phone (optional)", text: sandboxBinding(merchant.shop, \.phone))
                .textContentType(.telephoneNumber).accessibilityIdentifier("sandboxPhone")
            TextField("Street address", text: sandboxBinding(merchant.shop, \.street))
                .textContentType(.streetAddressLine1).accessibilityIdentifier("sandboxStreet")
            TextField("City", text: sandboxBinding(merchant.shop, \.city))
                .textContentType(.addressCity).accessibilityIdentifier("sandboxCity")
            TextField("State / region", text: sandboxBinding(merchant.shop, \.region))
                .textContentType(.addressState).accessibilityIdentifier("sandboxRegion")
            TextField("Postal code", text: sandboxBinding(merchant.shop, \.postalCode))
                .textContentType(.postalCode).accessibilityIdentifier("sandboxPostalCode")
            TextField("Country code", text: sandboxBinding(merchant.shop, \.country))
                .textContentType(.countryName).accessibilityIdentifier("sandboxCountry")
            Text("Used only for this sandbox checkout and never saved to Crumb history.")
                .font(CrumbType.caption).foregroundStyle(CrumbColor.ink3)
            Button("Continue to sandbox shipping") {
                Task { await model.submitSandboxContact(for: merchant.shop) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!sandbox.canSubmitContact)
            .accessibilityIdentifier("sandboxSubmitContact")
        }
        .textFieldStyle(.roundedBorder)
        // Container, not clobber: without `.contain` every text field reports "sandboxContactForm"
        // instead of its own sandboxFirstName/… id (#61).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandboxContactForm")
    }

    private func sandboxReview(
        merchant: AppModel.MerchantCheckout,
        session: CheckoutSession,
        sandbox: AppModel.SandboxCheckout,
        allowsPlacement: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Text("Review sandbox order").font(CrumbType.title2)
            Text("Merchant of Record: \(merchant.shop.name)")
                .font(CrumbType.headline).accessibilityIdentifier("sandboxMerchantOfRecord")
            ForEach(session.lineItems) { line in
                HStack {
                    Text("\(line.quantity) × \(line.title)")
                    Spacer()
                    Text(CheckoutCurrency.formatted(
                        minorUnits: line.unitPrice * line.quantity, currency: session.currency))
                }
            }
            ForEach(session.fulfillmentGroups) { group in
                Picker(group.title, selection: shippingBinding(merchant.shop, group: group)) {
                    ForEach(group.options) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .accessibilityIdentifier("sandboxShipping.\(group.id)")
            }
            if !session.fulfillmentGroups.isEmpty {
                Button("Update sandbox shipping & totals") {
                    Task { await model.submitSandboxContact(for: merchant.shop) }
                }
                .accessibilityIdentifier("sandboxUpdateShipping")
            }
            ForEach(session.totals.indices, id: \.self) { index in
                let total = session.totals[index]
                HStack {
                    Text(total.displayText ?? total.type.capitalized)
                    Spacer()
                    Text(CheckoutCurrency.formatted(minorUnits: total.amount, currency: session.currency))
                }
            }
            Text("Sandbox terms: this local test simulates merchant review and completion. No payment, shipment, or real order occurs.")
                .font(CrumbType.caption)
                .foregroundStyle(CrumbColor.ink2)
                .padding(CrumbMetrics.Space.s)
                .background(CrumbColor.ochre.opacity(0.1), in: RoundedRectangle(cornerRadius: CrumbMetrics.Radius.tile))
                .accessibilityIdentifier("sandboxLegalDisclosure")
            if let expires = session.expiresAt {
                Text("Sandbox checkout expires \(expires.formatted(date: .abbreviated, time: .shortened)).")
                    .font(CrumbType.caption).accessibilityIdentifier("sandboxExpiry")
            }
            if allowsPlacement, session.status == .readyForComplete, !sandbox.isDirty {
                Toggle("I reviewed the merchant, items, shipping, and authoritative total.",
                       isOn: acknowledgementBinding(merchant.shop))
                    .accessibilityIdentifier("sandboxReviewAcknowledgement")
                Button("Place sandbox order") {
                    Task { await model.completeSandboxCheckout(for: merchant.shop) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sandbox.isAcknowledged)
                .accessibilityIdentifier("sandboxPlaceOrder")
            } else {
                Text("Update shipping to receive the merchant's final sandbox total before review.")
                    .font(CrumbType.caption).foregroundStyle(CrumbColor.ink2)
                    .accessibilityIdentifier("sandboxNeedsShippingUpdate")
            }
            Text("SANDBOX — no payment method is charged and no real order is created.")
                .font(CrumbType.caption).foregroundStyle(CrumbColor.ochre)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandboxReview")
    }

    private func sandboxConfirmation(session: CheckoutSession) -> some View {
        VStack(alignment: .leading, spacing: CrumbMetrics.Space.m) {
            Label("Sandbox order complete", systemImage: "checkmark.seal.fill")
                .font(CrumbType.title2).foregroundStyle(CrumbColor.pine)
            if let order = session.order {
                Text("SANDBOX order ID: \(order.id)")
                    .font(CrumbType.headline).textSelection(.enabled)
                    .accessibilityIdentifier("sandboxOrderID")
                if let url = order.permalinkURL {
                    Link("View sandbox confirmation", destination: url)
                }
            }
            Text("This sandbox result is not added to purchase history.")
                .font(CrumbType.caption).foregroundStyle(CrumbColor.ink3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sandboxConfirmation")
    }

    private func sandboxBinding<Value>(
        _ shop: Shop, _ keyPath: WritableKeyPath<AppModel.SandboxCheckout, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let sandbox = model.checkoutWorkflow?.merchants
                    .first(where: { $0.id == shop.id })?.sandbox else {
                    preconditionFailure("Missing sandbox checkout binding")
                }
                return sandbox[keyPath: keyPath]
            },
            set: { value in
                model.mutateSandboxPayload(for: shop) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func shippingBinding(_ shop: Shop, group: CheckoutFulfillmentGroup) -> Binding<String> {
        Binding(
            get: {
                model.checkoutWorkflow?.merchants.first(where: { $0.id == shop.id })?
                    .sandbox?.shippingSelections[group.id] ?? group.selectedOptionID ?? group.options.first?.id ?? ""
            },
            set: { value in
                model.mutateSandboxPayload(for: shop) {
                    $0.shippingSelections[group.id] = value
                }
            }
        )
    }

    private func messageSymbol(_ message: CheckoutMessage) -> String {
        switch message.type {
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: message.presentation == .disclosure ? "doc.text" : "info.circle"
        }
    }

    private func statusMessage(_ status: CheckoutStatus) -> String {
        switch status {
        case .incomplete: "The merchant needs more checkout information before you can continue."
        case .readyForComplete: "The merchant says this checkout is ready to complete, but Crumb does not place orders."
        case .completeInProgress: "The merchant is processing this checkout."
        case .requiresEscalation: "The merchant did not provide a safe continuation link."
        case .completed: "This checkout is complete."
        case .canceled: "This checkout was canceled."
        }
    }

    @ViewBuilder
    private func legalLinks(_ links: [CheckoutLink]) -> some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: CrumbMetrics.Space.xs) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Link(destination: link.url) {
                        Label(link.title ?? link.type.replacingOccurrences(of: "_", with: " ").capitalized,
                              systemImage: "doc.text")
                    }
                    .font(CrumbType.caption)
                    .foregroundStyle(CrumbColor.pine)
                }
            }
            .accessibilityIdentifier("checkoutLegalLinks")
        }
    }

    @ViewBuilder
    private func acknowledgementBinding(_ shop: Shop) -> Binding<Bool> {
        Binding(
            get: { model.checkoutWorkflow?.merchants.first(where: { $0.id == shop.id })?.sandbox?.isAcknowledged ?? false },
            set: { model.acknowledgeSandboxReview(for: shop, acknowledged: $0) }
        )
    }

    @ViewBuilder
    private func stateBadge(_ merchant: AppModel.MerchantCheckout) -> some View {
        switch merchant.state {
        case .preparing:
            Text("Preparing")
        case .prepared(let session):
            if let sandbox = merchant.sandbox {
                switch sandbox.phase {
                case .completed: Label("Sandbox complete", systemImage: "checkmark.seal.fill").foregroundStyle(CrumbColor.pine)
                case .expired: Text("Sandbox expired")
                case .review where session.status == .readyForComplete && !sandbox.isDirty: Text("Sandbox ready")
                case .updating, .completing: Text("Sandbox processing")
                default: Text("Sandbox input needed")
                }
            } else {
            switch session.status {
            case .requiresEscalation where session.continueURL != nil:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(CrumbColor.pine)
            case .completed:
                Label("Completed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(CrumbColor.pine)
            case .canceled:
                Text("Canceled")
            default:
                Text("Not actionable")
            }
            }
        case .unsupported:
            Text("Unavailable")
        case .failed:
            Text("Needs retry")
        }
    }
}
