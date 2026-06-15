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
        // Test-only: property-based testing (generators + shrinking).
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "1.0.0"),
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
                .product(name: "PropertyBased", package: "swift-property-based"),
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
                // Larger multi-chapter corpus (Pinker, Rationality) — exercises
                // read-aloud continuation ACROSS reading-order resource
                // (chapter) boundaries, which the smaller fixtures cannot.
                .copy("Fixtures/rationality.epub"),
                // Real-world PDF (Velleman, "How to Prove It") — a justified
                // academic text whose paragraphs are marked by first-line
                // indentation with NO extra inter-paragraph leading. Exercises
                // PDF read-aloud paragraph detection on layout that the
                // vertical-gap heuristic alone cannot split.
                .copy("Fixtures/how-to-prove-it.pdf"),
            ]
        ),
    ]
)
