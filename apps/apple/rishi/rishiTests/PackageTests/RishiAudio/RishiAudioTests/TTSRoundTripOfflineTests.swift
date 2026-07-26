@testable import rishi
import Testing
import Foundation


#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import AudioToolbox

/// Deterministic OFFLINE sibling of the TTS->STT round-trip (RESEARCH §5.4).
///
/// The real round-trip (`TTSRoundTripNetworkTests`) needs the worker speech +
/// transcribe routes and so is opt-in/env-gated. This sibling gives the default
/// `swift test` lane round-trip-SHAPED coverage with ZERO network: it decodes the
/// checked-in `alice-p0.mp3` fixture (committed in plan 29-02) through
/// `MP3StreamDecoder` and asserts non-empty PCM — the decode seam that the live
/// round-trip exercises against fresh worker audio — and confirms the ground-truth
/// expected-text fixture ships so the network sibling has a shared source of truth.
@Suite("TTS round-trip (offline)", .serialized)
struct TTSRoundTripOfflineTests {

    private func makeTargetFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    }

    private func loadFixtureMP3() throws -> Data {
        let url = try #require(
            PackageTestResourceBundle.bundle.url(forResource: "alice-p0", withExtension: "mp3", subdirectory: "Fixtures"),
            "alice-p0.mp3 fixture must be bundled via Package.swift resources"
        )
        return try Data(contentsOf: url)
    }

    private func loadExpectedText() throws -> String {
        let url = try #require(
            PackageTestResourceBundle.bundle.url(forResource: "alice-p0-expected", withExtension: "txt", subdirectory: "Fixtures"),
            "alice-p0-expected.txt ground-truth fixture must be bundled via Package.swift resources"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("offline fixture decodes to non-empty PCM and ships ground-truth text")
    func offlineRoundTripDecodesFixture() async throws {
        // Ground truth ships alongside the audio so the network sibling shares it.
        let expected = try loadExpectedText().trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!expected.isEmpty, "expected-text fixture must be non-empty ground truth")

        let mp3 = try loadFixtureMP3()
        #expect(mp3.count > 1000, "fixture must be a real MP3, not an error body")

        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        let stream = decoder.pcmStream()

        let drain = Task<Int, Never> {
            var total = 0
            for await chunk in stream {
                total += Int(chunk.buffer.frameLength)
            }
            return total
        }

        // Feed in slices with cooperative yields so the AudioFileStream parser
        // callbacks drain into the converter before finish() flushes (mirrors the
        // streamed feed; a single append+finish would race the callbacks).
        let sliceSize = 4096
        var index = 0
        while index < mp3.count {
            let end = min(index + sliceSize, mp3.count)
            try await decoder.append(mp3.subdata(in: index..<end), passageId: "0")
            index = end
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await decoder.finish()

        let frames = await drain.value
        #expect(frames > 0, "offline round-trip sibling must decode the fixture to non-empty PCM frames")
    }
}
#endif
