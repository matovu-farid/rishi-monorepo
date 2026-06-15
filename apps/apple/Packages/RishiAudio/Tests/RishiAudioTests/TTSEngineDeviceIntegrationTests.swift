import Testing
import Foundation
@testable import RishiAudio

// Integration test that runs the FULL real audio stack — real AVAudioEngine
// (AVAudioEngineAdapter), real AVAudioSession (AVAudioSessionConfigurator),
// real TTSEngine + real TTSPassageTracker + a real MP3 fixture. The host unit
// tests use FakeAudioEngine (which always "plays"), so they can never reproduce
// the device-only next/prev silence. This one exercises the real session +
// engine restart that the jump path performs, on the iOS SIMULATOR.
//
// Gated to iOS: AVAudioSessionConfigurator only exists on iOS/macCatalyst, and
// only the simulator gives us a real AVAudioSession to (mis)configure. Run via:
//   xcodebuild test -scheme RishiAudio -destination 'platform=iOS Simulator,name=iPhone 17' \
//     -only-testing:RishiAudioTests/TTSEngineDeviceIntegrationTests
#if canImport(AVFAudio) && os(iOS)
import AVFAudio

@Suite("TTSEngine device integration", .serialized)
struct TTSEngineDeviceIntegrationTests {

    private final class IdBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func append(_ id: String) { lock.withLock { ids.append(id) } }
        func snapshot() -> [String] { lock.withLock { ids } }
    }

    private func loadFixtureChunks(sliceSize: Int = 4096) throws -> [Data] {
        let url = try #require(
            Bundle.module.url(forResource: "alice-p0", withExtension: "mp3", subdirectory: "Fixtures"),
            "alice-p0.mp3 fixture must be bundled"
        )
        let data = try Data(contentsOf: url)
        var chunks: [Data] = []
        var i = 0
        while i < data.count {
            let end = min(i + sliceSize, data.count)
            chunks.append(data.subdata(in: i..<end))
            i = end
        }
        return chunks
    }

    private func poll(timeout: TimeInterval, _ predicate: @Sendable () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// PLAY paragraph 0, then NEXT (jump = stop + start) to paragraph 1, with the
    /// REAL audio stack. Asserts the highlight (tracker passage stream) follows
    /// the play head 0 -> 1. If the real session/engine restart silently fails on
    /// a switch — the device next/prev bug — passage 1 never schedules a buffer,
    /// currentPassageId never becomes "1", and this FAILS.
    @Test("real stack: play then next moves the highlight 0 -> 1", .timeLimit(.minutes(1)))
    func realStackPlayThenNextMovesHighlight() async throws {
        let chunks = try loadFixtureChunks()
        let configurator = AVAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let adapter = AVAudioEngineAdapter()
        let streamer = TTSStreamer(source: FakeTTSChunkSource(chunks: chunks))
        let state = await MainActor.run { TTSPlaybackState() }
        let engine = TTSEngine(
            streamer: streamer,
            decoderFactory: { try MP3StreamDecoder(targetFormat: $0) },
            engine: adapter,
            coordinator: coordinator,
            state: state
        )
        let tracker = TTSPassageTracker()
        await tracker.attach(state: state)
        let seen = IdBox()
        let consumer = Task { for await pid in await tracker.passageStream() { seen.append(pid) } }

        await engine.start(request: TTSStreamRequest(text: "alpha", voice: "alloy", speed: 1.0, passageId: "0"))
        await poll(timeout: 8) { seen.snapshot().contains("0") }
        #expect(seen.snapshot().contains("0"), "PLAY must highlight paragraph 0 (passage 0 reached the engine)")

        // NEXT: bridge jump = full stop then fresh start of the next passage.
        await engine.stop()
        await engine.start(request: TTSStreamRequest(text: "bravo", voice: "alloy", speed: 1.0, passageId: "1"))
        await poll(timeout: 8) { seen.snapshot().contains("1") }

        #expect(seen.snapshot().contains("1"), "NEXT must move the highlight to paragraph 1 — real-stack next/prev silence reproduces HERE if it fails")

        // Non-blocking teardown: awaiting a full engine.stop() while passage 1 is
        // still rendering hangs the headless test (the real AVAudioEngine teardown
        // needs a run loop the test does not pump). The assertions above are the
        // contract; cancel the observers and let the local engine deinit.
        consumer.cancel()
        await tracker.detach()
    }
}
#endif
