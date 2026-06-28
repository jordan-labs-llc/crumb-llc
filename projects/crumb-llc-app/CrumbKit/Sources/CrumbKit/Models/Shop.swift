import Foundation

/// A merchant that sells products in the Crumb catalog.
///
/// In a live integration this maps to a UCP merchant; here it is seed data.
public struct Shop: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
