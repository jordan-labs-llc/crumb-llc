// swift-tools-version: 6.2
import PackageDescription

// CrumbArt holds Crumb's *programmatic* vector art — the crumb mark, the app-icon
// composition, the in-app brand badge, refined product-card art, and the empty/hero
// illustrations — as plain SwiftUI so the same shapes drive both the live UI and the
// rasterized app-icon PNGs.
//
// Two products:
//   • `CrumbArt`           — the SwiftUI library the app links (iOS/macOS/visionOS).
//   • `crumb-art-render`   — a macOS helper that rasterizes the icon to PNGs via
//                            `ImageRenderer`, so the assets stay reproducible in-repo
//                            (`swift run --package-path CrumbArt crumb-art-render`).
let package = Package(
    name: "CrumbArt",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "CrumbArt", targets: ["CrumbArt"]),
    ],
    targets: [
        .target(
            name: "CrumbArt",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // macOS-only tools: built for the host when invoked with `swift run`, never pulled
        // into the iOS/visionOS app build (the app links only the library product).
        .executableTarget(
            name: "crumb-art-render",
            dependencies: ["CrumbArt"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "crumb-art-market",
            dependencies: ["CrumbArt"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
