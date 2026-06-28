import SwiftUI

/// Cross-platform sheet sizing. `presentationDetents` is unavailable on macOS, so these
/// helpers apply detents on iOS / iPadOS / visionOS and fall back to a sensible window
/// size on macOS.
extension View {
    /// A medium-then-large sheet (e.g. the taste profile).
    @ViewBuilder
    func crumbExpandableSheet() -> some View {
        #if os(macOS)
        self.frame(minWidth: 460, minHeight: 560)
        #else
        self.presentationDetents([.medium, .large])
        #endif
    }

    /// A compact, single-height sheet (e.g. the checkout handoff, Siri demo).
    @ViewBuilder
    func crumbCompactSheet() -> some View {
        #if os(macOS)
        self.frame(minWidth: 440, minHeight: 500)
        #else
        self.presentationDetents([.medium])
        #endif
    }
}
