import SwiftUI

extension Color {
    /// Builds a color from a packed-RGB hex value (e.g. `0x1C4B43`).
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

/// Crumb's color tokens.
///
/// Deliberately **not** the default "cream + serif + terracotta" look: warm paper on a
/// greige board, deep pine green as the primary, and ochre reserved only for delight
/// moments (kit fills, affirmations, stars).
enum CrumbColor {
    /// App background — warm paper.
    static let paper = Color(hex: 0xF3EEE4)
    /// Cards / raised surfaces.
    static let raised = Color(hex: 0xFBF8F1)
    /// Primary text.
    static let ink = Color(hex: 0x221E18)
    /// Secondary text.
    static let ink2 = Color(hex: 0x6F675A)
    /// Faint text.
    static let ink3 = Color(hex: 0xA39A8A)
    /// **Primary** — CTAs, the kit tray.
    static let pine = Color(hex: 0x1C4B43)
    /// Pine tint backgrounds.
    static let pineSoft = Color(hex: 0xE3ECE7)
    /// **Accent** — delight moments only (kit fills, affirmations, stars).
    static let ochre = Color(hex: 0xCC8A3A)
    /// Hairlines — ink at 10%.
    static let line = Color(hex: 0x221E18, opacity: 0.10)
}

extension LinearGradient {
    /// A two-stop gradient from packed-RGB hex stops, used for product card art.
    /// Falls back gracefully if fewer than two stops are supplied.
    init(crumbStops stops: [UInt32]) {
        let colors = stops.map { Color(hex: $0) }
        let resolved: [Color]
        switch colors.count {
        case 0: resolved = [CrumbColor.pine, CrumbColor.ink]
        case 1: resolved = [colors[0], colors[0]]
        default: resolved = colors
        }
        self.init(
            colors: resolved,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
