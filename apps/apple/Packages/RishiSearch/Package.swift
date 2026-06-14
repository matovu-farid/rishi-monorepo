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
        .package(url: "https://github.com/unum-cloud/usearch", from: "2.25.3"),
    ],
    targets: [
        .target(
            name: "RishiSearch",
            dependencies: [
                "RishiCore",
                "RishiLogging",
                .product(name: "USearch", package: "usearch"),
            ],
            resources: [
                .process("Resources/AllMiniLML6V2.mlmodel"),
                .process("Resources/vocab.txt"),
                .copy("Resources/LICENSE-AllMiniLML6V2.txt"),
            ]
        ),
        .testTarget(
            name: "RishiSearchTests",
            dependencies: ["RishiSearch"]
        ),
    ]
)
