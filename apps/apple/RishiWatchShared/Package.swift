// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiWatchShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "RishiWatchShared", targets: ["RishiWatchShared"]),
    ],
    targets: [
        .target(name: "RishiWatchShared"),
        .testTarget(name: "RishiWatchSharedTests", dependencies: ["RishiWatchShared"]),
    ]
)
