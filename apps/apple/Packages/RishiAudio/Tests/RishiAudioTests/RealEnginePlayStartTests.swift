import Foundation
import Testing
#if canImport(AVFAudio)
import AVFAudio
@testable import RishiAudio

/// Locks the real-engine play-start ordering precondition called out in
/// 29-RESEARCH §3.2 / §7 ("targetFormat zero-format trap").
///
/// The decoder factory in `TTSEngine.start(request:)` reads
/// `engine.targetFormat` to build the `MP3StreamDecoder` (TTSEngine.swift:64),
/// and `start(request:)` calls `engine.attach()` then `engine.start()` BEFORE
/// that read (TTSEngine.swift:62-64). The hazard: if `targetFormat`
/// (`mainMixerNode.outputFormat(forBus:0)`) is read before `engine.start()`,
/// it can come back with a 0 sample-rate / 0-channel format, and an
/// `AVAudioConverter` built against that silently produces NO PCM — i.e. TTS
/// runs with no audible output and no error.
///
/// This suite exercises the REAL `AVAudioEngineAdapter` (compiled on the
/// macOS host per RishiAudio's `.macOS(.v14)` platform) rather than the
/// `FakeAudioEngine`, which always returns a hard-coded 48k/2ch format and
/// therefore cannot catch the zero-format trap. It asserts:
///
///  1. `attach()` then `start()` succeed without throwing.
///  2. After `start()`, `targetFormat` has a non-zero sample rate AND a
///     non-zero channel count — the precondition the decoder factory relies
///     on. A regression that reads the format before starting, or that breaks
///     the mixer wiring, fails loudly here instead of as silent device-only
///     "no audio".
///  3. `start()` is idempotent (a second call on a running engine is a
///     no-op), matching `AVAudioEngineAdapter.start()`'s `if !engine.isRunning`
///     guard — so `TTSEngine`'s teardown/restart cycle cannot double-start.
///
/// NOTE: this does NOT render audio (headless render targets are finicky on
/// CI, see 29-RESEARCH §7). The audible end-to-end path stays the Task-3
/// hardware checkpoint. This test pins the cheap, deterministic precondition.
@Suite("AVAudioEngineAdapter play-start ordering precondition")
struct RealEnginePlayStartTests {

    @Test("attach + start yield a valid (non-zero) targetFormat for the decoder")
    func startPrecedesValidTargetFormat() throws {
        let adapter = AVAudioEngineAdapter()

        try adapter.attach()
        try adapter.start()

        // The decoder factory reads this immediately after start(). It must be
        // a usable format, not the zero-format trap.
        let format = adapter.targetFormat
        #expect(format.sampleRate > 0, "targetFormat sample rate must be > 0 after start() — a 0-rate format silently breaks AVAudioConverter (no PCM, no error)")
        #expect(format.channelCount > 0, "targetFormat must have >= 1 channel after start()")

        adapter.stop()
    }

    @Test("start() is idempotent on an already-running engine")
    func startIsIdempotent() throws {
        let adapter = AVAudioEngineAdapter()
        try adapter.attach()
        try adapter.start()
        // Second start must not throw (mirrors the `if !engine.isRunning`
        // guard) so TTSEngine's stop/restart cycle is safe.
        try adapter.start()
        adapter.stop()
    }
}
#endif
