// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiLogging",
    platforms: [.iOS(.v17), .macCatalyst(.v17)],
    products: [
        .library(name: "RishiLogging", targets: ["RishiLogging"]),
    ],
    targets: [
        .target(name: "RishiLogging"),
    ]
)
