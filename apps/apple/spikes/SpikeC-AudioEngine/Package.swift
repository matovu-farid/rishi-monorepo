// swift-tools-version: 6.0
// Spike C — AVAudioEngine chunked MP3 streaming from /api/audio/speech
// Throwaway prototype. NOT part of the main `rishi` app target.
// Purpose: measure latency-to-first-sample for streaming TTS playback
// using AVAudioEngine + AVAudioConverter against the worker's
// /api/audio/speech MP3 stream. Pass threshold: < 1000 ms.

import PackageDescription

let package = Package(
    name: "SpikeCAudioEngine",
    platforms: [
        .iOS(.v17),
        .macCatalyst(.v17),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SpikeCAudioEngine", targets: ["SpikeCAudioEngine"]),
    ],
    dependencies: [
        // No third-party dependencies — first-party AVFAudio only, per the
        // STACK.md "no third-party audio lib" directive for v1.
    ],
    targets: [
        .executableTarget(
            name: "SpikeCAudioEngine"
        ),
    ]
)
