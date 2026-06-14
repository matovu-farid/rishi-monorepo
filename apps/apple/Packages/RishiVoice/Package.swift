// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiVoice",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiVoice", targets: ["RishiVoice"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiAPI"),
        .package(path: "../RishiAuth"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiLogging"),
        .package(path: "../RishiAudio"),
        .package(path: "../RishiSearch"),
        .package(path: "../RishiTesting"), // test-only consumer
        .package(
            url: "https://github.com/m1guelpf/swift-realtime-openai.git",
            revision: "46f393d9e2e60724aadc30062f75ee73bbcdb8fc"
        ),
    ],
    targets: [
        .target(
            name: "RishiVoice",
            dependencies: [
                "RishiCore",
                "RishiAPI",
                "RishiAuth",
                "RishiUIKit",
                "RishiLogging",
                "RishiAudio",
                .product(name: "RishiSearch", package: "RishiSearch"),
                .product(name: "RealtimeAPI", package: "swift-realtime-openai"),
            ]
        ),
        .testTarget(
            name: "RishiVoiceTests",
            dependencies: [
                "RishiVoice",
                "RishiCore",
                "RishiAPI",
                "RishiAudio",
                .product(name: "RishiSearch", package: "RishiSearch"),
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
