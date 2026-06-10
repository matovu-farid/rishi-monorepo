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
            ]
        ),
    ]
)
