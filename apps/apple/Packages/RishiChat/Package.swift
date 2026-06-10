// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiChat",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiChat", targets: ["RishiChat"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiDB"),
        .package(path: "../RishiAPI"),
        .package(path: "../RishiAuth"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiTesting"), // test-only consumer
    ],
    targets: [
        .target(
            name: "RishiChat",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiDB",
                "RishiAPI",
                "RishiAuth",
                "RishiLogging",
            ]
        ),
        .testTarget(
            name: "RishiChatTests",
            dependencies: [
                "RishiChat",
                "RishiCore",
                "RishiDB",
                "RishiAPI",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
