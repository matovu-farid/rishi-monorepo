// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiAPI",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiAPI", targets: ["RishiAPI"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiLogging"),
    ],
    targets: [
        .target(
            name: "RishiAPI",
            dependencies: [
                "RishiCore",
                "RishiLogging",
            ]
        ),
        .testTarget(
            name: "RishiAPITests",
            dependencies: ["RishiAPI"]
        ),
    ]
)
