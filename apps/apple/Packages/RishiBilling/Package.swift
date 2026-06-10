// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiBilling",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiBilling", targets: ["RishiBilling"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiAPI"),
        .package(path: "../RishiAuth"),
        .package(path: "../RishiTesting"),
    ],
    targets: [
        .target(
            name: "RishiBilling",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiLogging",
                "RishiAPI",
                "RishiAuth",
            ]
        ),
        .testTarget(
            name: "RishiBillingTests",
            dependencies: [
                "RishiBilling",
                "RishiCore",
                "RishiAPI",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
