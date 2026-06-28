import Foundation

/// Configuration for talking to UCP: the catalog base URL and an API key.
///
/// Real values are read from a **gitignored** `Secrets.plist` (a `Secrets.example.plist`
/// template is committed). This scaffold never requires a real key — it runs entirely on
/// ``MockUCPClient`` — so a missing `Secrets.plist` resolves to ``mock``.
public struct UCPConfig: Sendable, Equatable {
    public let baseURL: URL
    public let apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Whether a real API key is present. `false` means "run on the mock".
    public var hasLiveCredentials: Bool {
        !apiKey.isEmpty && apiKey != Self.placeholderKey
    }

    static let placeholderKey = "REPLACE_WITH_UCP_API_KEY"

    /// A safe, keyless default used by the scaffold.
    public static let mock = UCPConfig(
        // swiftlint:disable:next force_unwrapping — compile-time-constant valid URL
        baseURL: URL(string: "https://catalog.example.invalid/ucp")!,
        apiKey: placeholderKey
    )

    /// Loads config from a `Secrets.plist` bundled with the app, falling back to ``mock``
    /// when the file is absent or incomplete. The keys mirror `Secrets.example.plist`:
    /// `UCP_BASE_URL` and `UCP_API_KEY`.
    public static func load(from bundle: Bundle = .main) -> UCPConfig {
        guard
            let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = raw as? [String: Any],
            let urlString = dict["UCP_BASE_URL"] as? String,
            let baseURL = URL(string: urlString),
            let apiKey = dict["UCP_API_KEY"] as? String
        else {
            return .mock
        }
        return UCPConfig(baseURL: baseURL, apiKey: apiKey)
    }
}
