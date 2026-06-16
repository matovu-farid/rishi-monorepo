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
        // Rishi fork (branch rishi-compat): patches the realtime `usage`
        // token-detail models to be optional so OpenAI's transcription usage
        // shape decodes (upstream m1guelpf/swift-realtime-openai @46f393d hard-
        // requires cachedTokens/outputTokenDetails, which OpenAI now omits).
        .package(
            url: "https://github.com/matovu-farid/swift-realtime-openai.git",
            revision: "0471374392dce1b42b5711f74f9ecdbc421604c6"
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
