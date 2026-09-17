// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiE2EHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RishiE2EHost", targets: ["RishiE2EHost"]),
        .executable(name: "rishi-e2e-host", targets: ["RishiE2EHostCLI"]),
    ],
    targets: [
        .target(name: "RishiE2EHost"),
        .executableTarget(name: "RishiE2EHostCLI", dependencies: ["RishiE2EHost"]),
        .testTarget(name: "RishiE2EHostTests", dependencies: ["RishiE2EHost"]),
    ]
)
