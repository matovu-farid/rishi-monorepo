// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiCore",
    platforms: [.iOS(.v17), .macCatalyst(.v17)],
    products: [
        .library(name: "RishiCore", targets: ["RishiCore"]),
    ],
    targets: [
        .target(name: "RishiCore"),
        .testTarget(
            name: "RishiCoreTests",
            dependencies: ["RishiCore"]
        ),
    ]
)
