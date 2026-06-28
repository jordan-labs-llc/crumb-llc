import SwiftUI

/// Crumb's three type roles, mapped to Apple-native faces. All use relative text styles
/// so Dynamic Type is respected throughout.
///
/// - **Display / UI titles:** SF Pro Rounded, weights 600–700.
/// - **Curator voice:** New York (serif) italic — used **only** where Crumb "speaks"
///   (curator notes, product rationales, sign-offs). The serif signals voice; it is
///   never used for chrome.
/// - **Body / data / captions:** SF Pro (default).
enum CrumbType {

    // MARK: Display / UI titles (rounded)

    static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let title = Font.system(.title, design: .rounded).weight(.semibold)
    static let title2 = Font.system(.title2, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
    static let pill = Font.system(.subheadline, design: .rounded).weight(.semibold)

    // MARK: Body / data / captions (default)

    static let body = Font.system(.body, design: .default)
    static let callout = Font.system(.callout, design: .default)
    static let caption = Font.system(.caption, design: .default)
    static let captionStrong = Font.system(.caption, design: .default).weight(.semibold)

    // MARK: Curator voice (serif italic — Crumb's voice ONLY)

    /// A curator note / sign-off at title scale.
    static let curatorTitle = Font.system(.title3, design: .serif).italic()
    /// A product rationale or inline curator aside at body scale.
    static let curator = Font.system(.body, design: .serif).italic()
    /// A small curator caption (e.g. a one-line sign-off).
    static let curatorCaption = Font.system(.callout, design: .serif).italic()
}
