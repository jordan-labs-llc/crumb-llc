import SwiftUI

/// The art palette — the exact Crumb brand hexes, owned here so the vector art (and the
/// icon exporter, which can't see the app target) has one source of truth.
///
/// These **mirror** the app's `CrumbColor` tokens by value (paper / raised / ink / pine /
/// pineSoft / ochre); the extra `pineDeep`, `ochreDeep`, `earth*`, and `crust` stops are
/// art-only depth shades used to give the crumb warmth and the grounds subtle depth. Keep
/// the shared names in sync with `CrumbColor` if those ever change.
public enum ArtPalette {
    /// Warm paper — the app background.
    public static let paper = Color(hex: 0xF3EEE4)
    /// Raised surfaces / cards.
    public static let raised = Color(hex: 0xFBF8F1)
    /// Primary ink.
    public static let ink = Color(hex: 0x221E18)
    /// Secondary ink.
    public static let ink2 = Color(hex: 0x6F675A)
    /// Faint ink.
    public static let ink3 = Color(hex: 0xA39A8A)

    /// Primary — deep pine.
    public static let pine = Color(hex: 0x1C4B43)
    /// A darker pine for ground depth.
    public static let pineDeep = Color(hex: 0x143630)
    /// A lifted pine for top-light.
    public static let pineLift = Color(hex: 0x265B52)
    /// Pine tint background.
    public static let pineSoft = Color(hex: 0xE3ECE7)

    /// Accent — ochre (delight only).
    public static let ochre = Color(hex: 0xCC8A3A)
    /// A deeper ochre.
    public static let ochreDeep = Color(hex: 0xB9863F)
    /// The warm crumb's lit face.
    public static let crumbLit = Color(hex: 0xE7B873)
    /// The warm crumb's shaded face.
    public static let crumbShade = Color(hex: 0x9A6A33)
    /// Toasted crumb edge.
    public static let crust = Color(hex: 0x7A5226)

    /// Earthy browns for card art.
    public static let earth = Color(hex: 0x7A5A3A)
    public static let earthDeep = Color(hex: 0x4F3A24)
    public static let stone = Color(hex: 0x5D6552)
    public static let stoneDeep = Color(hex: 0x3B4035)
}

extension Color {
    /// Builds a color from a packed-RGB hex value (e.g. `0x1C4B43`). Mirrors the app's
    /// `Color(hex:)`, re-declared here because `CrumbArt` doesn't link the app target.
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
