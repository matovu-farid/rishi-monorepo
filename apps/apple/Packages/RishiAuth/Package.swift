// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiAuth",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiAuth", targets: ["RishiAuth"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiAPI"),
    ],
    targets: [
        .target(
            name: "RishiAuth",
            dependencies: [
                "RishiCore",
                "RishiLogging",
                "RishiAPI",
            ]
        ),
        .testTarget(
            name: "RishiAuthTests",
            dependencies: ["RishiAuth"]
        ),
    ]
)
