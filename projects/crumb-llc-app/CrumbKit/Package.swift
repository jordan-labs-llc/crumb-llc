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
        .executable(name: "crumb-query-harness", targets: ["CrumbQueryHarness"]),
        .executable(name: "crumb-query-collect", targets: ["CrumbQueryCollector"]),
    ],
    targets: [
        .target(
            name: "CrumbKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CrumbQueryHarness",
            dependencies: ["CrumbKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CrumbQueryCollector",
            dependencies: ["CrumbKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CrumbKitTests",
            dependencies: ["CrumbKit"],
            path: "Tests",
            sources: ["CrumbKitTests"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
