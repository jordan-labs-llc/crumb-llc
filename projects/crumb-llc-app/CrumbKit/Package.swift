// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CrumbKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        .library(name: "CrumbKit", targets: ["CrumbKit"]),
    ],
    targets: [
        .target(
            name: "CrumbKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CrumbKitTests",
            dependencies: ["CrumbKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
