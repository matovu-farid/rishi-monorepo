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
        // VENDORED, locally-maintained copy of the realtime SDK (we own it; no
        // upstream-compatibility concern). Absorbed from our fork
        // matovu-farid/swift-realtime-openai (was pinned revision
        // 0471374…) into the monorepo so we can patch and keep patching it —
        // e.g. the `usage` token-detail optional fix and the WebRTC peer-leak
        // teardown. Edit the source directly under
        // `apps/apple/Packages/swift-realtime-openai`.
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
                .product(name: "RishiTesting", package: "RishiTesting"),
            ]
        ),
    ]
)
