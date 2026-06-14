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
            ]
        ),
        .testTarget(
            name: "RishiSearchTests",
            dependencies: ["RishiSearch"]
        ),
    ]
)
