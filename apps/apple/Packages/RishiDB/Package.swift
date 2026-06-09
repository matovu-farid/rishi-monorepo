// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiDB",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiDB", targets: ["RishiDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(path: "../RishiCore"),
        .package(path: "../RishiLogging"),
    ],
    targets: [
        .target(
            name: "RishiDB",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "RishiCore",
                "RishiLogging",
            ]
        ),
        .testTarget(
            name: "RishiDBTests",
            dependencies: [
                "RishiDB",
                "RishiCore",
            ]
        ),
    ]
)
