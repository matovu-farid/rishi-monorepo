// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiAppleMCP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rishi-apple-mcp", targets: ["RishiAppleMCP"]),
    ],
    targets: [
        .executableTarget(name: "RishiAppleMCP"),
        .testTarget(name: "RishiAppleMCPTests", dependencies: ["RishiAppleMCP"]),
    ]
)
