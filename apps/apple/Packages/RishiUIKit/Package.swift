// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiUIKit",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiUIKit", targets: ["RishiUIKit"]),
    ],
    targets: [
        .target(
            name: "RishiUIKit",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "RishiUIKitTests",
            dependencies: ["RishiUIKit"]
        ),
    ]
)
