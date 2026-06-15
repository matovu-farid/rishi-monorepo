// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiCore",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiCore", targets: ["RishiCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/x-sheep/swift-property-based.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "RishiCore"),
        .testTarget(
            name: "RishiCoreTests",
            dependencies: [
                "RishiCore",
                .product(name: "PropertyBased", package: "swift-property-based"),
            ]
        ),
    ]
)
