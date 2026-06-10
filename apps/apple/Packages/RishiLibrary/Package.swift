// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiLibrary",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiLibrary", targets: ["RishiLibrary"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiDB"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiTesting"), // test-only consumer
        // Phase 6 (06-01): migrated off weichsel/ZIPFoundation to readium/ZIPFoundation
        // to resolve the SPM package-identity collision (both share identity "zipfoundation").
        // Readium 3.9 transitively depends on this fork, so RishiLibrary aligns on it directly.
        .package(url: "https://github.com/readium/ZIPFoundation.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "RishiLibrary",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiDB",
                "RishiLogging",
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                .process("Resources/Bundled"),
            ]
        ),
        .testTarget(
            name: "RishiLibraryTests",
            dependencies: [
                "RishiLibrary",
                "RishiCore",
                .product(name: "RishiTesting", package: "RishiTesting"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
