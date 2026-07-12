import Foundation

public enum MockCheckoutFailurePoint: Equatable, Sendable {
    case update
    case complete
}

public struct MockCheckoutConfiguration: Sendable {
    public var clock: @Sendable () async -> Date
    public var expiresAfter: TimeInterval
    public var expiresImmediately: Bool
    public var priceChangeMinorUnits: Int
    public var failurePoint: MockCheckoutFailurePoint?

    public init(
        now: Date = Date(timeIntervalSince1970: 1_800_000_000),
        clock: (@Sendable () async -> Date)? = nil,
        expiresAfter: TimeInterval = 3_600,
        expiresImmediately: Bool = false,
        priceChangeMinorUnits: Int = 0,
        failurePoint: MockCheckoutFailurePoint? = nil
    ) {
        self.clock = clock ?? { now }
        self.expiresAfter = expiresAfter
        self.expiresImmediately = expiresImmediately
        self.priceChangeMinorUnits = priceChangeMinorUnits
        self.failurePoint = failurePoint
    }
}

/// In-memory ``UCPClient`` backed by ``SeedData`` — no network, no API key.
///
/// `searchCatalog` supports two query styles:
/// 1. A **mission keyword** (e.g. `"hike"`, `"coffee"`, `"desk"`, or words from a
///    mission's title) returns that mission's candidate products in curated order.
/// 2. Otherwise a simple **keyword filter** across product name, rationale, and shop.
public struct MockUCPClient: UCPClient {

    /// Optional artificial latency, in nanoseconds, to exercise async UI states.
    /// Defaults to `0` so tests stay fast and deterministic.
    public let simulatedLatency: UInt64
    private let checkoutStore: MockCheckoutStore

    public init(
        simulatedLatency: UInt64 = 0,
        checkoutConfiguration: MockCheckoutConfiguration = .init()
    ) {
        self.simulatedLatency = simulatedLatency
        self.checkoutStore = MockCheckoutStore(configuration: checkoutConfiguration)
    }

    public func searchCatalog(
        _ query: String,
        placements: [Placement] = [.organic]
    ) async throws -> [Product] {
        try await tick()

        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return SeedData.products }

        // 1. Mission match — id, one of the mission's live search queries, or any word
        //    from the mission title. Matching `searchQueries` lets the live fan-out
        //    (which calls this once per query) collapse back to the curated seed deck.
        if let mission = SeedData.missions.first(where: { mission in
            mission.id == needle
                || mission.searchQueries.contains { $0.lowercased() == needle }
                || mission.title.lowercased().contains(needle)
                || needle.split(separator: " ").contains { word in
                    mission.title.lowercased().contains(word)
                }
        }) {
            let candidates = candidates(for: mission)
            return filtered(candidates, placements: placements)
        }

        // 2. Keyword filter across the whole catalog.
        let hits = SeedData.products.filter { product in
            product.name.lowercased().contains(needle)
                || product.rationale.lowercased().contains(needle)
                || product.shop.name.lowercased().contains(needle)
        }
        return filtered(hits, placements: placements)
    }

    public func product(id: Product.ID) async throws -> Product {
        try await tick()
        guard let product = SeedData.productsByID[id] else {
            throw UCPError.productNotFound(id)
        }
        return product
    }

    public func assembleCart(_ items: [KitItem]) async throws -> Cart {
        try await tick()
        return Cart(items: items)
    }

    public func createCheckout(
        for shop: Shop,
        items: [KitItem],
        idempotencyKey: String
    ) async throws -> CheckoutSession {
        try await tick()
        let merchantItems = items.filter { $0.product.shop.id == shop.id }
        guard !merchantItems.isEmpty else { throw UCPError.emptyCheckout(shop.id) }

        let lines = merchantItems.enumerated().map { index, kitItem in
            let amount = Self.minorUnits(kitItem.variant.price)
            return CheckoutLineItem(
                id: "line_\(index + 1)",
                itemID: kitItem.variant.id,
                title: kitItem.product.name,
                unitPrice: amount,
                quantity: 1,
                totals: [CheckoutTotal(type: "subtotal", amount: amount)]
            )
        }
        return try await checkoutStore.create(
            shop: shop,
            lines: lines,
            idempotencyKey: idempotencyKey
        )
    }

    public func getCheckout(id: String) async throws -> CheckoutSession {
        try await tick()
        return try await checkoutStore.get(id: id)
    }

    public func updateCheckout(
        id: String,
        update: CheckoutUpdateCommand,
        idempotencyKey: String
    ) async throws -> CheckoutSession {
        try await tick()
        return try await checkoutStore.update(id: id, command: update, key: idempotencyKey)
    }

    public func completeCheckout(
        id: String,
        authorization: CheckoutCompletionAuthorization,
        idempotencyKey: String
    ) async throws -> CheckoutSession {
        try await tick()
        return try await checkoutStore.complete(
            id: id,
            authorization: authorization,
            key: idempotencyKey
        )
    }

    public func discardCheckout(id: String) async throws {
        try await tick()
        await checkoutStore.discard(id: id)
    }

    public func checkoutHandoff(for shop: Shop, in cart: Cart) async throws -> URL {
        try await tick()
        let shopItems = cart.items(for: shop)
        guard !shopItems.isEmpty else {
            throw UCPError.emptyShopHandoff(shop.id)
        }
        // Mock `continue_url`: a deterministic, non-routable handoff target. A live client
        // would return the merchant's real secure-checkout URL from the catalog response.
        let ids = shopItems.map(\.variant.id).joined(separator: ",")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "checkout.example.invalid"
        components.path = "/\(shop.id)"
        components.queryItems = [URLQueryItem(name: "items", value: ids)]
        guard let url = components.url else {
            throw UCPError.emptyShopHandoff(shop.id)
        }
        return url
    }

    // MARK: - Helpers

    /// The candidate products for a mission, in the mission's curated order.
    public func candidates(for task: ShoppingTask) -> [Product] {
        task.candidateIDs.compactMap { SeedData.productsByID[$0] }
    }

    /// In the mock, all seed results are organic. When the caller does not request
    /// `.organic`, return nothing (there are no promoted seed items yet).
    private func filtered(_ products: [Product], placements: [Placement]) -> [Product] {
        placements.contains(.organic) ? products : []
    }

    private func tick() async throws {
        guard simulatedLatency > 0 else { return }
        try await Task.sleep(nanoseconds: simulatedLatency)
    }
    private static func minorUnits(_ amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * 100).intValue
    }
}

private actor MockCheckoutStore {
    private struct UpdateReplay {
        let commandDigest: UInt64
        let session: CheckoutSession
    }

    private let configuration: MockCheckoutConfiguration
    private var sessions: [String: CheckoutSession] = [:]
    private var createKeys: [String: (fingerprint: String, session: CheckoutSession)] = [:]
    private var updateKeys: [String: UpdateReplay] = [:]
    private var completeKeys: [String: CheckoutSession] = [:]
    private var priceChangedSessions: Set<String> = []

    init(configuration: MockCheckoutConfiguration) {
        self.configuration = configuration
    }

    func create(shop: Shop, lines: [CheckoutLineItem], idempotencyKey: String) async throws -> CheckoutSession {
        let fingerprint = shop.id + "|" + lines.map { "\($0.itemID):\($0.quantity)" }.joined(separator: ",")
        if let replay = createKeys[idempotencyKey] {
            guard replay.fingerprint == fingerprint else { throw UCPError.idempotencyConflict(idempotencyKey) }
            return replay.session
        }

        let id = "mock_checkout_" + String(Self.stableDigest(shop.id + "|" + idempotencyKey), radix: 16)
        let subtotal = lines.reduce(0) { $0 + ($1.unitPrice * $1.quantity) }
        let now = await configuration.clock()
        let expiry = configuration.expiresImmediately
            ? now.addingTimeInterval(-1)
            : now.addingTimeInterval(configuration.expiresAfter)
        let session = CheckoutSession(
            id: id,
            shop: shop,
            status: .incomplete,
            currency: "USD",
            lineItems: lines,
            totals: [
                CheckoutTotal(type: "subtotal", amount: subtotal),
                CheckoutTotal(type: "total", amount: subtotal),
            ],
            messages: [CheckoutMessage(
                type: .error,
                code: "missing",
                path: "$.buyer.email",
                content: "Contact and shipping information are required.",
                severity: .recoverable
            )],
            links: [CheckoutLink(
                type: "privacy_policy",
                url: URL(string: "https://checkout.example.invalid/privacy")!,
                title: "Sandbox privacy policy"
            )],
            expiresAt: expiry,
            provenance: .sandbox(handlerID: CheckoutCompletionAuthorization.crumbSandboxPay.handlerInstanceID),
            paymentHandlers: [CheckoutPaymentHandlerSummary(
                id: CheckoutCompletionAuthorization.crumbSandboxPay.handlerInstanceID,
                specificationName: "llc.jordanlabs.crumb_sandbox_pay",
                displayName: "Crumb Sandbox Pay",
                version: "2026-04-08",
                instrumentTypes: ["sandbox"],
                isSandbox: true
            )]
        )
        sessions[id] = session
        createKeys[idempotencyKey] = (fingerprint, session)
        return session
    }

    func get(id: String) async throws -> CheckoutSession {
        let session = try existing(id)
        try await ensureCurrent(session)
        return session
    }

    func update(id: String, command: CheckoutUpdateCommand, key: String) async throws -> CheckoutSession {
        let replayKey = id + "|" + key
        let digest = Self.commandDigest(command)
        if let replay = updateKeys[replayKey] {
            guard replay.commandDigest == digest else { throw UCPError.idempotencyConflict(key) }
            return replay.session
        }
        let current = try existing(id)
        try await ensureCurrent(current)
        guard current.status != .completed && current.status != .canceled else {
            throw UCPError.invalidCheckoutState(id)
        }
        if configuration.failurePoint == .update { throw UCPError.invalidCheckoutUpdate(id) }

        let validation = Self.validationMessages(buyer: command.buyer, address: command.shippingAddress)
        let options = Self.shippingOptions
        let selected = command.selections.first { $0.groupID == "shipment_1" }?.optionID
        if let selected, !options.contains(where: { $0.id == selected }) {
            throw UCPError.invalidCheckoutUpdate("unknown_fulfillment_option")
        }
        var lines = current.lineItems
        var messages = validation + current.messages.filter { $0.code == "price_changed" }
        var appliedPriceChange = false
        if configuration.priceChangeMinorUnits != 0,
           !priceChangedSessions.contains(id),
           !lines.isEmpty {
            let first = lines[0]
            let price = first.unitPrice + configuration.priceChangeMinorUnits
            guard price >= 0 else { throw UCPError.invalidCheckoutUpdate("negative_price") }
            lines[0] = CheckoutLineItem(
                id: first.id,
                itemID: first.itemID,
                title: first.title,
                unitPrice: price,
                quantity: first.quantity,
                totals: [CheckoutTotal(type: "subtotal", amount: price * first.quantity)]
            )
            messages.append(CheckoutMessage(
                type: .warning,
                code: "price_changed",
                path: "$.line_items[0]",
                content: "The merchant updated this item's price.",
                presentation: .notice
            ))
            appliedPriceChange = true
        }
        let group = CheckoutFulfillmentGroup(
            id: "shipment_1",
            title: "Shipping",
            lineItemIDs: lines.map(\.id),
            options: options,
            selectedOptionID: selected
        )
        let subtotal = lines.reduce(0) { $0 + ($1.unitPrice * $1.quantity) }
        var totals = [CheckoutTotal(type: "subtotal", amount: subtotal)]
        let status: CheckoutStatus
        if validation.isEmpty, let selected,
           let shipping = options.first(where: { $0.id == selected })?.totals.last?.amount {
            let tax = (subtotal + shipping) * 8 / 100
            totals += [
                CheckoutTotal(type: "fulfillment", displayText: "Shipping", amount: shipping),
                CheckoutTotal(type: "tax", displayText: "Estimated tax", amount: tax),
                CheckoutTotal(type: "total", amount: subtotal + shipping + tax),
            ]
            status = .readyForComplete
        } else {
            totals.append(CheckoutTotal(type: "total", amount: subtotal))
            status = .incomplete
            if validation.isEmpty {
                messages.append(CheckoutMessage(
                    type: .error,
                    code: "missing",
                    path: "$.fulfillment.groups[0].selected_option_id",
                    content: "Select a shipping option.",
                    severity: .recoverable
                ))
            }
        }
        let updated = Self.copy(
            current,
            status: status,
            lines: lines,
            totals: totals,
            messages: messages,
            buyer: command.buyer,
            address: command.shippingAddress,
            groups: [group]
        )
        sessions[id] = updated
        if appliedPriceChange { priceChangedSessions.insert(id) }
        updateKeys[replayKey] = UpdateReplay(commandDigest: digest, session: updated)
        return updated
    }

    func complete(
        id: String,
        authorization: CheckoutCompletionAuthorization,
        key: String
    ) async throws -> CheckoutSession {
        let replayKey = id + "|" + key
        if let replay = completeKeys[replayKey] { return replay }
        let current = try existing(id)
        try await ensureCurrent(current)
        if current.status == .completed { return current }
        guard current.status == .readyForComplete else { throw UCPError.invalidCheckoutState(id) }
        guard authorization.handlerInstanceID == CheckoutCompletionAuthorization.crumbSandboxPay.handlerInstanceID,
              current.paymentHandlers.contains(where: { $0.id == authorization.handlerInstanceID }) else {
            throw UCPError.paymentFailed("unsupported_sandbox_handler")
        }
        if configuration.failurePoint == .complete { throw UCPError.paymentFailed("injected_sandbox_failure") }

        let orderID = "SANDBOX-" + Self.safeIdentifier(id).uppercased()
        let completed = Self.copy(
            current,
            status: .completed,
            messages: [CheckoutMessage(
                type: .info,
                code: "sandbox_order_created",
                content: "Sandbox order created. No payment was processed."
            )],
            order: CheckoutOrderConfirmation(id: orderID)
        )
        sessions[id] = completed
        completeKeys[replayKey] = completed
        return completed
    }

    func discard(id: String) {
        sessions.removeValue(forKey: id)
        createKeys = createKeys.filter { $0.value.session.id != id }
        updateKeys = updateKeys.filter { !$0.key.hasPrefix(id + "|") }
        completeKeys = completeKeys.filter { !$0.key.hasPrefix(id + "|") }
        priceChangedSessions.remove(id)
    }

    private func existing(_ id: String) throws -> CheckoutSession {
        guard let session = sessions[id] else { throw UCPError.checkoutNotFound(id) }
        return session
    }

    private func ensureCurrent(_ session: CheckoutSession) async throws {
        let now = await configuration.clock()
        if let expiresAt = session.expiresAt, expiresAt <= now {
            throw UCPError.checkoutExpired(session.id)
        }
    }

    private static let shippingOptions = [
        CheckoutFulfillmentOption(
            id: "standard", title: "Standard shipping", description: "Arrives in 5–7 days",
            totals: [CheckoutTotal(type: "fulfillment", amount: 500)]
        ),
        CheckoutFulfillmentOption(
            id: "express", title: "Express shipping", description: "Arrives in 2–3 days",
            totals: [CheckoutTotal(type: "fulfillment", amount: 1_200)]
        ),
    ]

    private static func validationMessages(
        buyer: CheckoutBuyer,
        address: CheckoutPostalAddress
    ) -> [CheckoutMessage] {
        var result: [CheckoutMessage] = []
        let emailParts = buyer.email.split(separator: "@", omittingEmptySubsequences: false)
        let phoneIsValid = buyer.phoneNumber.map(Self.isE164) ?? true
        if buyer.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            buyer.lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            emailParts.count != 2 || !emailParts[1].contains(".") || !phoneIsValid {
            result.append(CheckoutMessage(
                type: .error, code: "invalid_buyer", path: "$.buyer",
                content: "Enter a valid name and email.", severity: .recoverable
            ))
        }
        let addressFields = [address.firstName, address.lastName, address.streetAddress,
                             address.locality, address.region, address.postalCode]
        let country = address.country.uppercased()
        let countryIsValid = country.count == 2 && country.unicodeScalars.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0)
        }
        let addressPhoneIsValid = address.phoneNumber.map(Self.isE164) ?? true
        if addressFields.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ||
            !countryIsValid || !addressPhoneIsValid {
            result.append(CheckoutMessage(
                type: .error, code: "address_undeliverable", path: "$.fulfillment",
                content: "Enter a complete shipping address.", severity: .recoverable
            ))
        }
        return result
    }

    private static func isE164(_ value: String) -> Bool {
        guard value.first == "+" else { return false }
        let digits = value.dropFirst()
        return (7...15).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }

    /// Non-reversible operation fingerprint: idempotency replay records retain no buyer PII.
    private static func commandDigest(_ command: CheckoutUpdateCommand) -> UInt64 {
        let values = [
            command.buyer.firstName, command.buyer.lastName, command.buyer.email,
            command.buyer.phoneNumber ?? "", command.shippingAddress.firstName,
            command.shippingAddress.lastName, command.shippingAddress.streetAddress,
            command.shippingAddress.extendedAddress ?? "", command.shippingAddress.locality,
            command.shippingAddress.region, command.shippingAddress.postalCode,
            command.shippingAddress.country, command.shippingAddress.phoneNumber ?? "",
            command.selections.sorted { $0.groupID < $1.groupID }
                .map { "\($0.groupID)=\($0.optionID)" }.joined(separator: "&"),
        ]
        return stableDigest(values.joined(separator: "\u{1F}"))
    }

    private static func stableDigest(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func safeIdentifier(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func copy(
        _ source: CheckoutSession,
        status: CheckoutStatus,
        lines: [CheckoutLineItem]? = nil,
        totals: [CheckoutTotal]? = nil,
        messages: [CheckoutMessage]? = nil,
        buyer: CheckoutBuyer? = nil,
        address: CheckoutPostalAddress? = nil,
        groups: [CheckoutFulfillmentGroup]? = nil,
        order: CheckoutOrderConfirmation? = nil
    ) -> CheckoutSession {
        CheckoutSession(
            id: source.id,
            shop: source.shop,
            status: status,
            currency: source.currency,
            lineItems: lines ?? source.lineItems,
            totals: totals ?? source.totals,
            messages: messages ?? source.messages,
            links: source.links,
            continueURL: source.continueURL,
            expiresAt: source.expiresAt,
            provenance: source.provenance,
            buyer: buyer ?? source.buyer,
            shippingAddress: address ?? source.shippingAddress,
            fulfillmentGroups: groups ?? source.fulfillmentGroups,
            paymentHandlers: source.paymentHandlers,
            order: order ?? source.order
        )
    }
}
