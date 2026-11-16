// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Trenches",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "Trenches",
            targets: ["Trenches"]
        ),
    ],
    targets: [
        .target(
            name: "Trenches",
            resources: [.copy("Shaders"), .copy("Assets")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
