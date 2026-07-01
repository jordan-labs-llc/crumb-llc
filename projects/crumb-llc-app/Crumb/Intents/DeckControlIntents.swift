import AppIntents
import Foundation
import CrumbKit

/// App Intents that act on the onscreen swipe deck via ``ProductEntity`` — the hands-free half of
/// Crumb's signature interaction. With the app open on Curate, "add this to my kit", "skip it", and
/// "why this one?" resolve the visible product and run through the *same* ``AppModel`` paths as a
/// swipe, so kit state, history, and price-sanity behave identically (issue #41).
///
/// All three act in place (`openAppWhenRun = false`) and hand back a spoken dialog plus a small
/// confirmation snippet. A stale id (the mission moved on, or the app cold-launched with no deck)
/// fails honestly with ``DeckIntentError/notOnDeck`` rather than silently doing nothing.

/// Add the resolved deck product to the kit — the voice equivalent of swiping "Add to kit".
struct AddToKitIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to kit"
    static let openAppWhenRun = false

    @Parameter(title: "Product")
    var product: ProductEntity

    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$product) to my kit")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let live = model.sessionProduct(id: product.id) else { throw DeckIntentError.notOnDeck }
        model.accept(live)
        let summary = "^[\(model.kit.count) item](inflect: true) · \(DeckControl.currency(model.kitSubtotal))"
        return .result(
            dialog: "Added \(product.name) to your kit.",
            view: DeckActionSnippet(product: product, message: "Added to your kit", kitSummary: summary)
        )
    }
}

/// Skip the resolved deck product — the voice equivalent of swiping "Skip".
struct SkipProductIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip product"
    static let openAppWhenRun = false

    @Parameter(title: "Product")
    var product: ProductEntity

    @Dependency var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Skip \(\.$product)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let live = model.sessionProduct(id: product.id) else { throw DeckIntentError.notOnDeck }
        model.skip(live)
        return .result(dialog: "Skipped \(product.name).")
    }
}

/// Speak (and show) the curator's "why this is you" rationale for a deck product — hands-free
/// "why this one?". Uses the entity's own snapshotted rationale, so it answers even if the deck has
/// since moved on.
struct ExplainPickIntent: AppIntent {
    static let title: LocalizedStringResource = "Explain a pick"
    static let openAppWhenRun = false

    @Parameter(title: "Product")
    var product: ProductEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Explain why \(\.$product) was picked")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let rationale = product.rationale.isEmpty
            ? "This one fits your taste for this mission."
            : product.rationale
        return .result(
            dialog: IntentDialog(stringLiteral: rationale),
            view: DeckActionSnippet(product: product, message: rationale)
        )
    }
}

/// A deck intent couldn't find its product on the live deck — the mission moved on, or the app
/// cold-launched with no deck. Surfaced to Siri/Shortcuts as a plain, honest line.
enum DeckIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notOnDeck

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notOnDeck: return "That product isn't on your deck anymore."
        }
    }
}

/// Small shared helpers for the deck intents.
enum DeckControl {
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f
    }()

    static func currency(_ amount: Decimal) -> String {
        currencyFormatter.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }
}
