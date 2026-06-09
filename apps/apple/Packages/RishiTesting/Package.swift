// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiTesting",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiTesting", targets: ["RishiTesting"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
    ],
    targets: [
        .target(
            name: "RishiTesting",
            dependencies: [
                .product(name: "RishiCore", package: "RishiCore"),
            ]
        ),
        .testTarget(
            name: "RishiTestingTests",
            dependencies: ["RishiTesting"]
        ),
    ]
)
