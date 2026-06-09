// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiTesting",
    platforms: [.iOS(.v17), .macCatalyst(.v17)],
    products: [
        .library(name: "RishiTesting", targets: ["RishiTesting"]),
    ],
    targets: [
        .target(name: "RishiTesting"),
    ]
)
