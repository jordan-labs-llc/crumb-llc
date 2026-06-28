// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CrumbKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
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
