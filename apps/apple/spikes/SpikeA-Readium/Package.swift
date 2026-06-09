// swift-tools-version: 6.0
// Spike A — Readium 3.9 on Mac Catalyst
// Throwaway prototype. NOT part of the main `rishi` app target.
// Purpose: verify Readium swift-toolkit 3.9 renders EPUB on Mac Catalyst with
// working pagination, TOC, and Decorations API.

import PackageDescription

let package = Package(
    name: "SpikeAReadium",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        // Required only to satisfy Readium's transitive dep graph on the
        // host macOS toolchain (`swift build` from the command line). The
        // shipping target is Catalyst, not native macOS.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SpikeAReadium", targets: ["SpikeAReadium"]),
    ],
    dependencies: [
        .package(url: "https://github.com/readium/swift-toolkit.git", from: "3.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpikeAReadium",
            dependencies: [
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit"),
                .product(name: "ReadiumNavigator", package: "swift-toolkit"),
            ],
            resources: [
                .process("Resources/sample.epub"),
            ]
        ),
    ]
)
