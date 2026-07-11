// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RishiAudio",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14)],
    products: [
        .library(name: "RishiAudio", targets: ["RishiAudio"]),
    ],
    dependencies: [
        .package(path: "../RishiCore"),
        .package(path: "../RishiAPI"),
        .package(path: "../RishiAuth"),
        .package(path: "../RishiUIKit"),
        .package(path: "../RishiLogging"),
        .package(url: "https://github.com/mihai8804858/swift-chunked-audio-player", from: "1.0.0"),
        .package(path: "../RishiTesting"), // test-only consumer
    ],
    targets: [
        .target(
            name: "RishiAudio",
            dependencies: [
                "RishiCore",
                "RishiAPI",
                "RishiAuth",
                "RishiUIKit",
                "RishiLogging",
                .product(name: "ChunkedAudioPlayer", package: "swift-chunked-audio-player"),
            ]
        ),
        .testTarget(
            name: "RishiAudioTests",
            dependencies: [
                "RishiAudio",
                "RishiCore",
                "RishiAPI",
                .product(name: "RishiTesting", package: "RishiTesting"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
