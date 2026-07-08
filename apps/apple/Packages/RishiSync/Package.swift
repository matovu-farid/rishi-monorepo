// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiSync",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiSync", targets: ["RishiSync"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiAPI"),
        .package(path: "../RishiAuth"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiLibrary"),
        .package(path: "../RishiTesting"), // test-only consumer
    ],
    targets: [
        .target(
            name: "RishiSync",
            dependencies: [
                "RishiCore",
                "RishiAPI",
                "RishiAuth",
                "RishiUIKit",
                "RishiLogging",
                "RishiLibrary",
            ]
        ),
        .testTarget(
            name: "RishiSyncTests",
            dependencies: [
                "RishiSync",
                "RishiCore",
                "RishiAPI",
                "RishiLibrary",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
