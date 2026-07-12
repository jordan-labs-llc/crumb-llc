import Foundation

/// The merchant-owned lifecycle of a UCP checkout session.
public enum CheckoutStatus: String, Codable, Hashable, Sendable {
    case incomplete
    case requiresEscalation = "requires_escalation"
    case readyForComplete = "ready_for_complete"
    case completeInProgress = "complete_in_progress"
    case completed
    case canceled
}

public enum CheckoutMessageType: String, Codable, Hashable, Sendable {
    case error
    case warning
    case info
}

public enum CheckoutMessageSeverity: String, Codable, Hashable, Sendable {
    case recoverable
    case requiresBuyerInput = "requires_buyer_input"
    case requiresBuyerReview = "requires_buyer_review"
    case unrecoverable
}

public enum CheckoutMessagePresentation: String, Codable, Hashable, Sendable {
    case notice
    case disclosure
}

public enum CheckoutProvenance: Codable, Hashable, Sendable {
    case live
    case sandbox(handlerID: String)
}

public struct CheckoutBuyer: Codable, Hashable, Sendable {
    public let firstName: String
    public let lastName: String
    public let email: String
    public let phoneNumber: String?

    public init(firstName: String, lastName: String, email: String, phoneNumber: String? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phoneNumber = phoneNumber
    }
}

public struct CheckoutPostalAddress: Codable, Hashable, Sendable {
    public let firstName: String
    public let lastName: String
    public let streetAddress: String
    public let extendedAddress: String?
    public let locality: String
    public let region: String
    public let postalCode: String
    public let country: String
    public let phoneNumber: String?

    public init(
        firstName: String,
        lastName: String,
        streetAddress: String,
        extendedAddress: String? = nil,
        locality: String,
        region: String,
        postalCode: String,
        country: String,
        phoneNumber: String? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.streetAddress = streetAddress
        self.extendedAddress = extendedAddress
        self.locality = locality
        self.region = region
        self.postalCode = postalCode
        self.country = country
        self.phoneNumber = phoneNumber
    }
}

public struct CheckoutFulfillmentSelection: Codable, Hashable, Sendable {
    public let groupID: String
    public let optionID: String

    public init(groupID: String, optionID: String) {
        self.groupID = groupID
        self.optionID = optionID
    }
}

public struct CheckoutUpdateCommand: Codable, Hashable, Sendable {
    public let buyer: CheckoutBuyer
    public let shippingAddress: CheckoutPostalAddress
    public let selections: [CheckoutFulfillmentSelection]

    public init(
        buyer: CheckoutBuyer,
        shippingAddress: CheckoutPostalAddress,
        selections: [CheckoutFulfillmentSelection] = []
    ) {
        self.buyer = buyer
        self.shippingAddress = shippingAddress
        self.selections = selections
    }
}

public struct CheckoutFulfillmentOption: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let totals: [CheckoutTotal]

    public init(id: String, title: String, description: String? = nil, totals: [CheckoutTotal]) {
        self.id = id
        self.title = title
        self.description = description
        self.totals = totals
    }
}

public struct CheckoutFulfillmentGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let lineItemIDs: [String]
    public let options: [CheckoutFulfillmentOption]
    public let selectedOptionID: String?

    public init(
        id: String,
        title: String,
        lineItemIDs: [String],
        options: [CheckoutFulfillmentOption],
        selectedOptionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.lineItemIDs = lineItemIDs
        self.options = options
        self.selectedOptionID = selectedOptionID
    }
}

public struct CheckoutPaymentHandlerSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let specificationName: String
    public let displayName: String
    public let version: String
    public let instrumentTypes: [String]
    public let isSandbox: Bool

    public init(
        id: String,
        specificationName: String,
        displayName: String,
        version: String,
        instrumentTypes: [String],
        isSandbox: Bool
    ) {
        self.id = id
        self.specificationName = specificationName
        self.displayName = displayName
        self.version = version
        self.instrumentTypes = instrumentTypes
        self.isSandbox = isSandbox
    }

    /// Source-compatible display alias. Protocol matching must use `specificationName`.
    public var name: String { displayName }
}

public struct CheckoutOrderConfirmation: Codable, Hashable, Sendable {
    public let id: String
    public let permalinkURL: URL?

    public init(id: String, permalinkURL: URL? = nil) {
        self.id = id
        self.permalinkURL = permalinkURL
    }
}

/// Foreground authorization for the compiled-in mock handler. Deliberately not Codable:
/// it cannot be persisted or confused with a real wallet credential.
public struct CheckoutCompletionAuthorization: Hashable, Sendable {
    public static let crumbSandboxPay = CheckoutCompletionAuthorization(
        handlerInstanceID: "crumb_sandbox_pay_default"
    )

    public let handlerInstanceID: String
    public var handlerID: String { handlerInstanceID }

    private init(handlerInstanceID: String) {
        self.handlerInstanceID = handlerInstanceID
    }
}

/// A UCP message. Warnings are display contracts, not merely diagnostic logging.
public struct CheckoutMessage: Codable, Hashable, Sendable {
    public let type: CheckoutMessageType
    public let code: String?
    public let path: String?
    public let content: String
    public let severity: CheckoutMessageSeverity?
    public let presentation: CheckoutMessagePresentation?

    public init(
        type: CheckoutMessageType,
        code: String? = nil,
        path: String? = nil,
        content: String,
        severity: CheckoutMessageSeverity? = nil,
        presentation: CheckoutMessagePresentation? = nil
    ) {
        self.type = type
        self.code = code
        self.path = path
        self.content = content
        self.severity = severity
        self.presentation = presentation
    }
}

/// A monetary line in the merchant's ordered UCP totals array, in ISO-4217 minor units.
public struct CheckoutTotal: Codable, Hashable, Sendable {
    public let type: String
    public let displayText: String?
    public let amount: Int

    public init(type: String, displayText: String? = nil, amount: Int) {
        self.type = type
        self.displayText = displayText
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey {
        case type, amount
        case displayText = "display_text"
    }
}

/// A merchant policy or help destination that accompanies a checkout.
public struct CheckoutLink: Codable, Hashable, Sendable {
    public let type: String
    public let url: URL
    public let title: String?

    public init(type: String, url: URL, title: String? = nil) {
        self.type = type
        self.url = url
        self.title = title
    }
}

/// ISO-4217 minor-unit conversion used for merchant-authoritative checkout amounts.
/// Most currencies use two digits, but assuming cents corrupts JPY, KWD, and others.
public enum CheckoutCurrency {
    public static func minorUnitDigits(for currency: String) -> Int {
        switch currency.uppercased() {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
             "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF":
            0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
            3
        case "CLF", "UYW":
            4
        default:
            2
        }
    }

    public static func decimal(minorUnits: Int, currency: String) -> Decimal {
        var divisor = Decimal(1)
        for _ in 0..<minorUnitDigits(for: currency) { divisor *= 10 }
        return Decimal(minorUnits) / divisor
    }

    public static func formatted(
        minorUnits: Int,
        currency: String,
        locale: Locale = .current
    ) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        formatter.locale = locale
        let digits = minorUnitDigits(for: currency)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(decimal: decimal(
            minorUnits: minorUnits,
            currency: currency
        ))) ?? "\(currency.uppercased()) \(minorUnits)"
    }
}

/// A merchant-authoritative checkout line. Prices are always minor currency units.
public struct CheckoutLineItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let itemID: String
    public let title: String
    public let unitPrice: Int
    public let quantity: Int
    public let totals: [CheckoutTotal]

    public init(
        id: String,
        itemID: String,
        title: String,
        unitPrice: Int,
        quantity: Int,
        totals: [CheckoutTotal]
    ) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.unitPrice = unitPrice
        self.quantity = quantity
        self.totals = totals
    }
}

/// One checkout session, scoped to exactly one merchant / Merchant of Record.
public struct CheckoutSession: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let shop: Shop
    public let status: CheckoutStatus
    public let currency: String
    public let lineItems: [CheckoutLineItem]
    public let totals: [CheckoutTotal]
    public let messages: [CheckoutMessage]
    public let links: [CheckoutLink]
    public let continueURL: URL?
    public let expiresAt: Date?
    public let provenance: CheckoutProvenance
    public let buyer: CheckoutBuyer?
    public let shippingAddress: CheckoutPostalAddress?
    public let fulfillmentGroups: [CheckoutFulfillmentGroup]
    public let paymentHandlers: [CheckoutPaymentHandlerSummary]
    public let order: CheckoutOrderConfirmation?

    public init(
        id: String,
        shop: Shop,
        status: CheckoutStatus,
        currency: String,
        lineItems: [CheckoutLineItem],
        totals: [CheckoutTotal],
        messages: [CheckoutMessage] = [],
        links: [CheckoutLink] = [],
        continueURL: URL? = nil,
        expiresAt: Date? = nil,
        provenance: CheckoutProvenance = .live,
        buyer: CheckoutBuyer? = nil,
        shippingAddress: CheckoutPostalAddress? = nil,
        fulfillmentGroups: [CheckoutFulfillmentGroup] = [],
        paymentHandlers: [CheckoutPaymentHandlerSummary] = [],
        order: CheckoutOrderConfirmation? = nil
    ) {
        self.id = id
        self.shop = shop
        self.status = status
        self.currency = currency
        self.lineItems = lineItems
        self.totals = totals
        self.messages = messages
        self.links = links
        self.continueURL = continueURL
        self.expiresAt = expiresAt
        self.provenance = provenance
        self.buyer = buyer
        self.shippingAddress = shippingAddress
        self.fulfillmentGroups = fulfillmentGroups
        self.paymentHandlers = paymentHandlers
        self.order = order
    }

    public var total: CheckoutTotal? { totals.last { $0.type == "total" } }
}

/// Independent result for one merchant in an app-orchestrated multi-store workflow.
public struct MerchantCheckoutOutcome: Identifiable, Hashable, Sendable {
    public var id: Shop.ID { shop.id }
    public let shop: Shop
    public let session: CheckoutSession?
    public let failure: String?

    public init(shop: Shop, session: CheckoutSession? = nil, failure: String? = nil) {
        precondition((session == nil) != (failure == nil), "Outcome must contain one result")
        self.shop = shop
        self.session = session
        self.failure = failure
    }
}

/// Ordered merchant results. UCP does not make completion across merchants atomic.
public struct CheckoutWorkflow: Hashable, Sendable {
    public let outcomes: [MerchantCheckoutOutcome]

    public init(outcomes: [MerchantCheckoutOutcome]) {
        self.outcomes = outcomes
    }

    public var sessions: [CheckoutSession] { outcomes.compactMap(\.session) }
    public var hasFailures: Bool { outcomes.contains { $0.failure != nil } }
}
