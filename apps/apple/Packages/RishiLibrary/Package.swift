// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiLibrary",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiLibrary", targets: ["RishiLibrary"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiDB"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiTesting"), // test-only consumer
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        .target(
            name: "RishiLibrary",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiDB",
                "RishiLogging",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                .process("Resources/Bundled"),
            ]
        ),
        .testTarget(
            name: "RishiLibraryTests",
            dependencies: [
                "RishiLibrary",
                "RishiCore",
                .product(name: "RishiTesting", package: "RishiTesting"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
