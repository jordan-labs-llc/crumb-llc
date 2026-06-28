import Foundation

/// How a catalog result earned its slot.
///
/// Maps to UCP's promoted-placement concept: `organic` results are ranked by relevance;
/// `affiliate` results are promoted (paid) placements. The curator surfaces and labels
/// these distinctly so the user always knows when something is promoted.
public enum Placement: Sendable, Hashable, Codable {
    case organic
    case affiliate
}
