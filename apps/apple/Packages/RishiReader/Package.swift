// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiReader",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiReader", targets: ["RishiReader"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiDB"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiLibrary"),
        .package(path: "../RishiTesting"), // test-only consumer
        // Spike A locked Readium 3.9 (PROVISIONAL PASS).
        .package(url: "https://github.com/readium/swift-toolkit.git", from: "3.9.0"),
    ],
    targets: [
        .target(
            name: "RishiReader",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiDB",
                "RishiLogging",
                "RishiLibrary",
                .product(name: "ReadiumShared", package: "swift-toolkit"),
                .product(name: "ReadiumNavigator", package: "swift-toolkit"),
                .product(name: "ReadiumStreamer", package: "swift-toolkit"),
                .product(name: "ReadiumAdapterGCDWebServer", package: "swift-toolkit"),
            ],
            resources: [
                .process("Resources/Bundled"),
            ]
        ),
        .testTarget(
            name: "RishiReaderTests",
            dependencies: [
                "RishiReader",
                "RishiCore",
                "RishiDB",
                "RishiLibrary",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ],
            resources: [
                // TEST-ONLY fixtures. Do NOT move these to the shipped
                // Sources/RishiReader/Resources/Bundled dir for purple-cow —
                // that 489K corpus would bloat the app binary. purple-cow is a
                // multi-page corpus used only by the read-aloud start-index
                // property tests. alice is mirrored here (it is ALSO shipped in
                // the source target) so the test bundle's `Bundle.module` can
                // resolve it when the package is built via its own scheme.
                .copy("Fixtures/alice.epub"),
                .copy("Fixtures/purple-cow.epub"),
            ]
        ),
    ]
)
