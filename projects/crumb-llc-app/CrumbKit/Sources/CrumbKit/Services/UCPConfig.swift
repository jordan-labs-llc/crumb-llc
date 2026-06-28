import Foundation

/// Points the app at the **Crumb broker** (`crumb-llc-api`) — the server that holds the
/// Shopify UCP credentials and fronts the catalog. The app never holds a Shopify secret
/// (Shopify App Store rule 5.9): the only on-device value is the broker's base URL, plus
/// an optional broker access key (a Function key — rotatable, broker-scoped, *not* a
/// Shopify credential).
///
/// Values are read from a **gitignored** `Secrets.plist` (template:
/// `Secrets.example.plist`). With no `Secrets.plist`, this resolves to ``mock`` and the
/// app runs entirely on ``MockUCPClient``.
public struct UCPConfig: Sendable, Equatable {
    /// Base URL of the broker (e.g. `https://func-crumb-agent-….azurewebsites.net`).
    /// `nil` means "no broker configured — use the mock".
    public let brokerBaseURL: URL?
    /// Optional broker access key sent as `x-broker-key`. Not a Shopify secret.
    public let brokerKey: String?

    public init(brokerBaseURL: URL?, brokerKey: String?) {
        self.brokerBaseURL = brokerBaseURL
        self.brokerKey = brokerKey
    }

    /// Whether a live broker is configured. `false` means "run on the mock".
    public var isLive: Bool { brokerBaseURL != nil }

    /// The keyless default used by the scaffold (no broker → mock data).
    public static let mock = UCPConfig(brokerBaseURL: nil, brokerKey: nil)

    /// Loads config from a bundled `Secrets.plist`, falling back to ``mock`` when the file
    /// is absent or incomplete. Keys mirror `Secrets.example.plist`:
    /// `CRUMB_API_BASE_URL` (required) and `CRUMB_API_KEY` (optional).
    public static func load(from bundle: Bundle = .main) -> UCPConfig {
        guard
            let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = raw as? [String: Any],
            let urlString = dict["CRUMB_API_BASE_URL"] as? String,
            !urlString.isEmpty,
            let baseURL = URL(string: urlString)
        else {
            return .mock
        }
        let key = (dict["CRUMB_API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return UCPConfig(brokerBaseURL: baseURL, brokerKey: key)
    }
}
