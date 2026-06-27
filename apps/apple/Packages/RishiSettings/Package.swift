// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiSettings",
    platforms: [.iOS(.v18), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiSettings", targets: ["RishiSettings"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiAPI"),
        .package(path: "../RishiAuth"),
        .package(path: "../RishiBilling"),
        .package(path: "../RishiSync"),
        .package(path: "../RishiAudio"),
        .package(path: "../RishiReader"),
        .package(path: "../RishiTesting"),
    ],
    targets: [
        .target(
            name: "RishiSettings",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiLogging",
                "RishiAPI",
                "RishiAuth",
                "RishiBilling",
                "RishiSync",
                "RishiAudio",
                "RishiReader",
            ]
        ),
        .testTarget(
            name: "RishiSettingsTests",
            dependencies: [
                "RishiSettings",
                "RishiCore",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
