// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiDB",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiDB", targets: ["RishiDB"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiTesting"),  // test-only consumer; not linked into RishiDB main target
    ],
    targets: [
        .target(
            name: "RishiDB",
            dependencies: [
                "RishiCore",
                "RishiLogging",
            ]
        ),
        .testTarget(
            name: "RishiDBTests",
            dependencies: [
                "RishiDB",
                "RishiCore",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
