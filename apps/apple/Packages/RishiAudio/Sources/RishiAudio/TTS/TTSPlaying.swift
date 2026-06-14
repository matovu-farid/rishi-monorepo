import Foundation

/// Testability seam at the top of the TTS pipeline (Phase 29, 29-RESEARCH §2).
///
/// `ReaderTTSBridge` consumes exactly this four-method subset of `TTSEngine`'s
/// public surface — start / pause / resume / stop. Depending on `any TTSPlaying`
/// instead of the concrete `TTSEngine` actor lets the bridge's
/// start/advance/stop/jump orchestration be driven deterministically in tests by
/// a `FakeTTSEngine`, with no live AVAudioEngine render cycle and no network.
///
/// `TTSEngine` conforms unchanged (its method signatures already match), so the
/// production object graph (AppDependencies) compiles byte-identically — a
/// `TTSEngine` still satisfies `any TTSPlaying`.
public protocol TTSPlaying: Sendable {
    func start(request: TTSStreamRequest) async
    func pause() async
    func resume() async
    func stop() async
}
