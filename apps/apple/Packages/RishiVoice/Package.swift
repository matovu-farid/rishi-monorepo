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
        .package(path: "../RishiLibrary"),
        .package(path: "../RishiTesting"), // test-only consumer
        .package(path: "../NumKong"),
        // Vendored realtime SDK with the compatibility patches we need for the
        // current server event shapes.
        .package(path: "../swift-realtime-openai"),
        // App-level manual control of WebRTC's process-global audio unit so it
        // re-initializes on every voice session (fixes dead-audio on session 2+).
        // Mirror the realtime SDK's exact requirement (`branch: "main"`) to avoid
        // a version conflict — the SDK already pins this package transitively.
        .package(
            url: "https://github.com/livekit/webrtc-xcframework.git",
            branch: "main"
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
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
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
                .product(name: "RishiLibrary", package: "RishiLibrary"),
                .product(name: "RishiTesting", package: "RishiTesting"),
            ],
            resources: [
                .copy("Fixtures/how-to-prove-it.pdf"),
            ]
        ),
    ]
)
