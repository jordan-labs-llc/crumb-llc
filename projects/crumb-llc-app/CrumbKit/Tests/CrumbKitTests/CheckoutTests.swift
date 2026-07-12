import Foundation
import Testing
@testable import CrumbKit

@Suite("UCP checkout domain")
struct CheckoutTests {
    private func item(_ id: String, shop: Shop, price: Decimal) -> KitItem {
        let product = Product(
            id: id,
            name: "Product \(id)",
            shop: shop,
            price: price,
            rating: 0,
            reviews: 0,
            rationale: "",
            symbol: "bag",
            gradient: SeedData.Gradient.pine,
            variants: [Variant(id: "\(id).variant", title: "Standard", price: price)]
        )
        return KitItem(product: product)
    }

    @Test("mock creates one deterministic multi-item merchant checkout")
    func mockMultiItem() async throws {
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let other = Shop(id: "other.example", name: "Other")
        let session = try await MockUCPClient().createCheckout(
            for: shop,
            items: [item("one", shop: shop, price: 12.50), item("two", shop: shop, price: 7), item("x", shop: other, price: 99)],
            idempotencyKey: "tap-1"
        )

        #expect(session.id.hasPrefix("mock_checkout_"))
        #expect(session.status == .incomplete)
        #expect(session.provenance == .sandbox(handlerID: "crumb_sandbox_pay_default"))
        #expect(session.paymentHandlers.first?.specificationName == "llc.jordanlabs.crumb_sandbox_pay")
        #expect(session.lineItems.map(\.itemID) == ["one.variant", "two.variant"])
        #expect(session.total?.amount == 1_950)
        #expect(session.continueURL == nil)
        #expect(session.messages.first?.severity == .recoverable)
        #expect(session.links.first?.type == "privacy_policy")
    }

    @Test("currency conversion honors ISO minor-unit exponents")
    func currencyMinorUnits() {
        #expect(CheckoutCurrency.minorUnitDigits(for: "JPY") == 0)
        #expect(CheckoutCurrency.decimal(minorUnits: 1_234, currency: "JPY") == Decimal(1_234))
        #expect(CheckoutCurrency.minorUnitDigits(for: "KWD") == 3)
        #expect(CheckoutCurrency.decimal(minorUnits: 1_234, currency: "KWD") == Decimal(string: "1.234"))
        #expect(CheckoutCurrency.decimal(minorUnits: 1_234, currency: "USD") == Decimal(string: "12.34"))

        let locale = Locale(identifier: "en_US")
        #expect(CheckoutCurrency.formatted(minorUnits: 1_234, currency: "JPY", locale: locale).contains("1,234"))
        #expect(CheckoutCurrency.formatted(minorUnits: 1_234, currency: "KWD", locale: locale).contains("1.234"))
    }

    @Test("mock refuses an empty merchant group")
    func mockEmptyGroup() async {
        let shop = Shop(id: "merchant.example", name: "Merchant")
        await #expect(throws: UCPError.emptyCheckout(shop.id)) {
            _ = try await MockUCPClient().createCheckout(for: shop, items: [], idempotencyKey: "key")
        }
    }

    @Test("workflow preserves merchant order and partial failures")
    func partialWorkflow() {
        let first = Shop(id: "first.example", name: "First")
        let second = Shop(id: "second.example", name: "Second")
        let session = CheckoutSession(
            id: "checkout-1", shop: first, status: .completed, currency: "USD",
            lineItems: [], totals: [CheckoutTotal(type: "total", amount: 100)]
        )
        let workflow = CheckoutWorkflow(outcomes: [
            MerchantCheckoutOutcome(shop: first, session: session),
            MerchantCheckoutOutcome(shop: second, failure: "Unavailable"),
        ])

        #expect(workflow.outcomes.map(\.shop.id) == [first.id, second.id])
        #expect(workflow.sessions == [session])
        #expect(workflow.hasFailures)
    }


    @Test("sandbox checkout collects shipping, selects fulfillment, and explicitly completes")
    func sandboxLifecycle() async throws {
        let client = MockUCPClient()
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let created = try await client.createCheckout(
            for: shop,
            items: [item("one", shop: shop, price: 10), item("two", shop: shop, price: 20)],
            idempotencyKey: "create-1"
        )
        #expect(created.status == .incomplete)
        #expect(created.paymentHandlers.first?.isSandbox == true)

        let contact = validUpdate()
        let shipping = try await client.updateCheckout(
            id: created.id, update: contact, idempotencyKey: "update-contact"
        )
        #expect(shipping.status == .incomplete)
        #expect(shipping.fulfillmentGroups.first?.options.map(\.id) == ["standard", "express"])

        let selected = CheckoutUpdateCommand(
            buyer: contact.buyer,
            shippingAddress: contact.shippingAddress,
            selections: [CheckoutFulfillmentSelection(groupID: "shipment_1", optionID: "standard")]
        )
        let ready = try await client.updateCheckout(
            id: created.id, update: selected, idempotencyKey: "update-shipping"
        )
        #expect(ready.status == .readyForComplete)
        #expect(ready.total?.amount == 3_780) // 3000 items + 500 shipping + 280 tax

        let completed = try await client.completeCheckout(
            id: created.id,
            authorization: .crumbSandboxPay,
            idempotencyKey: "complete-1"
        )
        #expect(completed.status == .completed)
        #expect(completed.order?.id.hasPrefix("SANDBOX-") == true)
        #expect(completed.messages.first?.content.contains("No payment was processed") == true)

        let duplicate = try await client.completeCheckout(
            id: created.id,
            authorization: .crumbSandboxPay,
            idempotencyKey: "complete-1"
        )
        #expect(duplicate.order == completed.order)
        #expect(try await client.getCheckout(id: created.id).order == completed.order)
    }

    @Test("sandbox update validates contact and address")
    func sandboxValidation() async throws {
        let client = MockUCPClient()
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let created = try await client.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "create"
        )
        let invalid = CheckoutUpdateCommand(
            buyer: CheckoutBuyer(firstName: "", lastName: "", email: "invalid"),
            shippingAddress: CheckoutPostalAddress(
                firstName: "", lastName: "", streetAddress: "", locality: "", region: "",
                postalCode: "", country: ""
            )
        )
        let response = try await client.updateCheckout(
            id: created.id, update: invalid, idempotencyKey: "invalid-update"
        )
        #expect(response.status == .incomplete)
        #expect(response.messages.map(\.code).contains("invalid_buyer"))
        #expect(response.messages.map(\.code).contains("address_undeliverable"))
    }

    @Test("sandbox injection covers price changes, failures, and expiry")
    func sandboxInjections() async throws {
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let priceClient = MockUCPClient(checkoutConfiguration: .init(priceChangeMinorUnits: 125))
        let priced = try await priceClient.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "price-create"
        )
        let changed = try await priceClient.updateCheckout(
            id: priced.id, update: validUpdate(), idempotencyKey: "price-update"
        )
        #expect(changed.lineItems.first?.unitPrice == 1_125)
        #expect(changed.messages.map(\.code).contains("price_changed"))

        let atomicClient = MockUCPClient(checkoutConfiguration: .init(priceChangeMinorUnits: 125))
        let atomic = try await atomicClient.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "atomic-create"
        )
        let base = validUpdate()
        let invalidSelection = CheckoutUpdateCommand(
            buyer: base.buyer,
            shippingAddress: base.shippingAddress,
            selections: [CheckoutFulfillmentSelection(groupID: "shipment_1", optionID: "unknown")]
        )
        await #expect(throws: UCPError.invalidCheckoutUpdate("unknown_fulfillment_option")) {
            _ = try await atomicClient.updateCheckout(
                id: atomic.id, update: invalidSelection, idempotencyKey: "atomic-invalid"
            )
        }
        let atomicChanged = try await atomicClient.updateCheckout(
            id: atomic.id, update: base, idempotencyKey: "atomic-valid"
        )
        #expect(atomicChanged.lineItems.first?.unitPrice == 1_125)

        let negativeClient = MockUCPClient(checkoutConfiguration: .init(priceChangeMinorUnits: -2_000))
        let negative = try await negativeClient.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "negative-create"
        )
        await #expect(throws: UCPError.invalidCheckoutUpdate("negative_price")) {
            _ = try await negativeClient.updateCheckout(
                id: negative.id, update: validUpdate(), idempotencyKey: "negative-update"
            )
        }

        let failedClient = MockUCPClient(checkoutConfiguration: .init(failurePoint: .update))
        let failed = try await failedClient.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "failure-create"
        )
        await #expect(throws: UCPError.invalidCheckoutUpdate(failed.id)) {
            _ = try await failedClient.updateCheckout(
                id: failed.id, update: validUpdate(), idempotencyKey: "failure-update"
            )
        }

        let expiredClient = MockUCPClient(checkoutConfiguration: .init(expiresImmediately: true))
        let expired = try await expiredClient.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "expiry-create"
        )
        await #expect(throws: UCPError.checkoutExpired(expired.id)) {
            _ = try await expiredClient.getCheckout(id: expired.id)
        }

        let paymentClient = MockUCPClient(checkoutConfiguration: .init(failurePoint: .complete))
        let payment = try await paymentClient.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "payment-create"
        )
        let command = validUpdate()
        let readyCommand = CheckoutUpdateCommand(
            buyer: command.buyer,
            shippingAddress: command.shippingAddress,
            selections: [CheckoutFulfillmentSelection(groupID: "shipment_1", optionID: "standard")]
        )
        _ = try await paymentClient.updateCheckout(
            id: payment.id, update: readyCommand, idempotencyKey: "payment-update"
        )
        await #expect(throws: UCPError.paymentFailed("injected_sandbox_failure")) {
            _ = try await paymentClient.completeCheckout(
                id: payment.id, authorization: .crumbSandboxPay, idempotencyKey: "payment-complete"
            )
        }
    }

    @Test("sandbox idempotency rejects key reuse with different input")
    func sandboxIdempotencyConflict() async throws {
        let client = MockUCPClient()
        let shop = Shop(id: "merchant.example", name: "Merchant")
        _ = try await client.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "same-key"
        )
        await #expect(throws: UCPError.idempotencyConflict("same-key")) {
            _ = try await client.createCheckout(
                for: shop, items: [item("two", shop: shop, price: 10)], idempotencyKey: "same-key"
            )
        }
    }

    @Test("session IDs remain isolated when sanitized keys would collide")
    func collisionResistantSessionIDs() async throws {
        let client = MockUCPClient()
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let first = try await client.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "a-b"
        )
        let second = try await client.createCheckout(
            for: shop, items: [item("two", shop: shop, price: 20)], idempotencyKey: "ab"
        )
        #expect(first.id != second.id)
        #expect(try await client.getCheckout(id: first.id).lineItems.first?.itemID == "one.variant")
        #expect(try await client.getCheckout(id: second.id).lineItems.first?.itemID == "two.variant")
    }

    @Test("concurrent same-key creates replay one session")
    func concurrentCreateReplay() async throws {
        let client = MockUCPClient()
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let cart = [item("one", shop: shop, price: 10)]
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await client.createCheckout(
                        for: shop, items: cart, idempotencyKey: "concurrent-key"
                    ).id
                }
            }
            var result: [String] = []
            for try await id in group { result.append(id) }
            return result
        }
        #expect(Set(ids).count == 1)
    }

    @Test("advanceable clock expires sessions and discard erases replay state")
    func expiryAndDiscard() async throws {
        let clock = CheckoutTestClock(Date(timeIntervalSince1970: 1_000))
        let client = MockUCPClient(checkoutConfiguration: .init(
            clock: { await clock.value }, expiresAfter: 60
        ))
        let shop = Shop(id: "merchant.example", name: "Merchant")
        let created = try await client.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "expiry"
        )
        await clock.advance(by: 61)
        await #expect(throws: UCPError.checkoutExpired(created.id)) {
            _ = try await client.getCheckout(id: created.id)
        }
        try await client.discardCheckout(id: created.id)
        await #expect(throws: UCPError.checkoutNotFound(created.id)) {
            _ = try await client.getCheckout(id: created.id)
        }
        let recreated = try await client.createCheckout(
            for: shop, items: [item("one", shop: shop, price: 10)], idempotencyKey: "expiry"
        )
        #expect(recreated.status == .incomplete)
        #expect(try await client.getCheckout(id: recreated.id) == recreated)
    }

    @Test("catalog-only defaults fail closed for native lifecycle")
    func lifecycleDefaultsFailClosed() async {
        let client = CheckoutCatalogOnlyClient()
        let update = validUpdate()
        await #expect(throws: UCPError.checkoutUnsupported("checkout")) {
            _ = try await client.getCheckout(id: "checkout")
        }
        await #expect(throws: UCPError.checkoutUnsupported("checkout")) {
            _ = try await client.updateCheckout(id: "checkout", update: update, idempotencyKey: "u")
        }
        await #expect(throws: UCPError.checkoutUnsupported("checkout")) {
            _ = try await client.completeCheckout(
                id: "checkout", authorization: .crumbSandboxPay, idempotencyKey: "c"
            )
        }
        await #expect(throws: UCPError.checkoutUnsupported("checkout")) {
            try await client.discardCheckout(id: "checkout")
        }
    }

    private func validUpdate() -> CheckoutUpdateCommand {
        CheckoutUpdateCommand(
            buyer: CheckoutBuyer(firstName: "Jane", lastName: "Doe", email: "jane@example.com"),
            shippingAddress: CheckoutPostalAddress(
                firstName: "Jane",
                lastName: "Doe",
                streetAddress: "123 Main St",
                locality: "Springfield",
                region: "IL",
                postalCode: "62701",
                country: "US"
            )
        )
    }
}

private actor CheckoutTestClock {
    private var now: Date
    init(_ now: Date) { self.now = now }
    var value: Date { now }
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

private struct CheckoutCatalogOnlyClient: UCPClient {
    func searchCatalog(_ query: String, placements: [Placement]) async throws -> [Product] { [] }
    func product(id: Product.ID) async throws -> Product { throw UCPError.productNotFound(id) }
    func assembleCart(_ items: [KitItem]) async throws -> Cart { Cart(items: items) }
    func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        throw UCPError.emptyShopHandoff(shop.id)
    }
}
