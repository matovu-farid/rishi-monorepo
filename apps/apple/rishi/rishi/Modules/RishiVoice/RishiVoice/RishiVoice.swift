import Foundation

/// RishiVoice — Feature-layer package owning the real-time voice chat surface.
///
/// Phase 10 lands a WebRTC voice session powered by
/// m1guelpf/swift-realtime-openai pinned at SHA
/// `46f393d9e2e60724aadc30062f75ee73bbcdb8fc` (per Spike B). The session
/// negotiates against `/api/realtime/client_secrets` for an ephemeral key,
/// then streams audio + transcript over WebRTC. Voice transcripts merge
/// back into the user's conversation log via MessageStore.
///
/// Depends DOWN on RishiCore (models + protocols), RishiAPI (WorkerClient +
/// RealtimeClientSecretsEndpoint), RishiAuth (token provider — wired via
/// WorkerClient), RishiUIKit (tokens), RishiLogging (os.Logger), and the
/// sibling Feature package RishiAudio (`AudioSessionCoordinator` for
/// preempting TTS during a voice session).
///
/// CONTRACT — VOICE-08: This package MUST NOT import CallKit anywhere.
/// iOS 18.4.1 introduced a CallKit regression that drops outgoing audio
/// mid-session; until Apple fixes it, voice chat ships WITHOUT CallKit
/// (no system call UI, no Lock Screen call ringer, no Recents entry).
/// A smoke test grep-asserts this in `PackageSmokeTests.swift`.
enum RishiVoice {
    /// Semantic version of the Feature surface. Bump on breaking API changes.
    static let version = "0.1.0-scaffold"

    /// SHA of `swift-realtime-openai` pinned by Spike B. Mirrored here as a
    /// compile-time constant so a future drift between Package.swift and
    /// the documented pin is loud (smoke test asserts).
    static let realtimeOpenAIPinnedSHA =
        "46f393d9e2e60724aadc30062f75ee73bbcdb8fc"
}
