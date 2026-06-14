// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiSearch",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiSearch", targets: ["RishiSearch"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiLogging"),
        // Phase 25 Plan 25-11 — consume the BookIndexingHook + PerBookTextExtractor
        // protocols from RishiLibrary so the production conformer can live in
        // RishiSearch (no cycle: RishiLibrary does NOT depend on RishiSearch).
        .package(path: "../RishiLibrary"),
        .package(url: "https://github.com/unum-cloud/usearch", from: "2.25.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.0"),
    ],
    targets: [
        .target(
            name: "RishiSearch",
            dependencies: [
                "RishiCore",
                "RishiLogging",
                "RishiLibrary",
                .product(name: "USearch", package: "usearch"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .process("Resources/AllMiniLML6V2.mlmodel"),
                .process("Resources/vocab.txt"),
                .copy("Resources/LICENSE-AllMiniLML6V2.txt"),
            ]
        ),
        .testTarget(
            name: "RishiSearchTests",
            dependencies: [
                "RishiSearch",
                "RishiLogging",
                "RishiLibrary",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "USearch", package: "usearch"),
            ]
        ),
    ]
)
