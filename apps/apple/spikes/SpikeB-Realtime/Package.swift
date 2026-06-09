// swift-tools-version: 6.0
// Spike B — swift-realtime-openai sustained voice session
// Throwaway prototype. NOT part of the main `rishi` app target.
// Purpose: verify m1guelpf/swift-realtime-openai can hold a 30-minute
// WebRTC voice session against the worker's ephemeral-key endpoint with
// VAD + tool-call parity to the electron client.

import PackageDescription

let package = Package(
    name: "SpikeBRealtime",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        // Required to satisfy LiveKit / WebRTC XCFramework transitive
        // requirements on the host triple when run through `swift build`.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SpikeBRealtime", targets: ["SpikeBRealtime"]),
    ],
    dependencies: [
        // Pin the resolved SHA in Package.resolved after `swift package resolve`.
        .package(url: "https://github.com/m1guelpf/swift-realtime-openai.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SpikeBRealtime",
            dependencies: [
                // Package exposes the library `RealtimeAPI` (the GitHub README's
                // marketing name "OpenAIRealtime" is not a product). The library
                // re-exports `Core`, `WebSocket`, `WebRTC`, `UI`, including the
                // `Conversation` type used by this harness.
                .product(name: "RealtimeAPI", package: "swift-realtime-openai"),
            ]
        ),
    ]
)
