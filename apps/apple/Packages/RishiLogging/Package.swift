// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiLogging",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiLogging", targets: ["RishiLogging"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.15.0"),
    ],
    targets: [
        .target(
            name: "RishiLogging",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(
            name: "RishiLoggingTests",
            dependencies: ["RishiLogging"]
        ),
    ]
)
