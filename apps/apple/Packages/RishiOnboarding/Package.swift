// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiOnboarding",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiOnboarding", targets: ["RishiOnboarding"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiLibrary"),
        .package(path: "../RishiTesting"),
    ],
    targets: [
        .target(
            name: "RishiOnboarding",
            dependencies: [
                "RishiCore",
                "RishiUIKit",
                "RishiLogging",
                "RishiLibrary",
            ]
        ),
        .testTarget(
            name: "RishiOnboardingTests",
            dependencies: [
                "RishiOnboarding",
                "RishiCore",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
