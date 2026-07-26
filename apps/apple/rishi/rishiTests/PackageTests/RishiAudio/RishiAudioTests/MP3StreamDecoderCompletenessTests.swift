@testable import rishi
import Testing
import Foundation


#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import AVFoundation
import AudioToolbox

/// Comprehensive decode-COMPLETENESS coverage for `MP3StreamDecoder`.
///
/// Why this suite exists: `RealMP3DecodeTests` only asserted `frames > 0`, which
/// passes when the decoder emits just the first ~200ms PCM buffer and silently
/// drops the rest. On device that surfaced as read-aloud playing "the first word"
/// then stopping (CoreAudio also logged
/// "N bytes of input provided, but packet descriptions (0) only account for 0
/// bytes"). A 2.4s fixture must decode to ~2.4s of PCM, and the decoded frame
/// total must NOT depend on how the compressed bytes were sliced on the way in.
@Suite("MP3 decode completeness", .serialized)
struct MP3StreamDecoderCompletenessTests {

    // alice-p0.mp3: 22050 Hz mono, ~2.403 s (afinfo). Decoded at the 48 kHz
    // target that ~2.403 s is ~115_356 frames. The truncation bug yields only
    // the first batch (~9_600 frames for a coarse feed).
    private let fixtureSeconds = 2.403
    private let targetSampleRate = 48000.0

    private func makeTargetFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 2, interleaved: false)!
    }

    private func loadFixtureMP3() throws -> Data {
        let url = try #require(
            PackageTestResourceBundle.bundle.url(forResource: "alice-p0", withExtension: "mp3", subdirectory: "Fixtures"),
            "alice-p0.mp3 fixture must be bundled via Package.swift resources"
        )
        return try Data(contentsOf: url)
    }

    /// Feed the fixture in fixed-size slices and return the total number of
    /// non-final PCM frames the decoder yields. Mirrors the streamed feed: a
    /// slice, a cooperative yield, then a settle before finish() so the
    /// AudioFileStream parser callbacks (which re-enter the actor via Task hops)
    /// drain before we flush.
    private func decodeTotalFrames(sliceSize: Int) async throws -> Int {
        let mp3 = try loadFixtureMP3()
        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        let request = TTSStreamRequest(text: "fixture", voice: "alloy", speed: 1.0)
        let stream = decoder.pcmStream()

        // Count ALL chunks: the final chunk now carries the last real audio
        // (the terminal marker is the last audio buffer, not a 0-frame buffer).
        let drain = Task<Int, Never> {
            var total = 0
            for await chunk in stream {
                total += Int(chunk.buffer.frameLength)
            }
            return total
        }

        var index = 0
        var sequenceIndex = 0
        while index < mp3.count {
            let end = min(index + sliceSize, mp3.count)
            try await decoder.append(
                TTSChunk.make(
                    request: request,
                    sequenceIndex: sequenceIndex,
                    data: mp3.subdata(in: index..<end)
                ),
                passageId: request.passageId
            )
            index = end
            sequenceIndex += 1
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await decoder.finish()
        return await drain.value
    }

    @Test("a 2.4s MP3 decodes to approximately 2.4s of PCM, not just the first buffer")
    func decodesFullDuration() async throws {
        let frames = try await decodeTotalFrames(sliceSize: 1024)
        let expected = fixtureSeconds * targetSampleRate // ~115_356
        // Allow generous slack for resampler priming/trailing, but the bug
        // (first ~200ms only) yields < 15_000 frames — far below this floor.
        let floor = Int(expected * 0.85) // ~98_000
        #expect(
            frames >= floor,
            "decoder truncated playback: got \(frames) frames (~\(Double(frames) / targetSampleRate)s), expected >= \(floor) (~\(fixtureSeconds)s)"
        )
    }

    @Test("decoded frame count is invariant to input slicing")
    func decodeIsIndependentOfSlicing() async throws {
        // Fine slices keep each per-batch convert under the output cap; coarse
        // slices exceed it. A correct decoder yields the same PCM either way.
        let fine = try await decodeTotalFrames(sliceSize: 1024)
        let medium = try await decodeTotalFrames(sliceSize: 4096)
        let coarse = try await decodeTotalFrames(sliceSize: 8192)

        let counts = [fine, medium, coarse]
        let maxFrames = counts.max() ?? 0
        let minFrames = counts.min() ?? 0
        let spread = maxFrames - minFrames
        #expect(
            maxFrames > 0 && spread <= Int(Double(maxFrames) * 0.05),
            "decoded frames depend on input chunking (fine=\(fine), medium=\(medium), coarse=\(coarse)); a correct decoder is slicing-invariant"
        )
    }

    /// Collect every chunk (including the final marker) as (frames, isFinal).
    private func decodeChunkShapes(sliceSize: Int) async throws -> [(frames: Int, isFinal: Bool)] {
        let mp3 = try loadFixtureMP3()
        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        let request = TTSStreamRequest(text: "fixture", voice: "alloy", speed: 1.0)
        let stream = decoder.pcmStream()
        let drain = Task<[(Int, Bool)], Never> {
            var out: [(Int, Bool)] = []
            for await chunk in stream {
                out.append((Int(chunk.buffer.frameLength), chunk.isFinal))
            }
            return out
        }
        var index = 0
        var sequenceIndex = 0
        while index < mp3.count {
            let end = min(index + sliceSize, mp3.count)
            try await decoder.append(
                TTSChunk.make(
                    request: request,
                    sequenceIndex: sequenceIndex,
                    data: mp3.subdata(in: index..<end)
                ),
                passageId: request.passageId
            )
            index = end
            sequenceIndex += 1
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await decoder.finish()
        return await drain.value.map { (frames: $0.0, isFinal: $0.1) }
    }

    @Test("the terminal isFinal chunk carries audio, not a 0-frame buffer")
    func finalChunkCarriesAudio() async throws {
        let chunks = try await decodeChunkShapes(sliceSize: 4096)
        let finals = chunks.filter(\.isFinal)
        #expect(finals.count == 1, "exactly one chunk must be marked final, got \(finals.count)")
        // A 0-frame final buffer's AVAudioPlayerNode completion is unreliable, so
        // TTSEngine.onBufferComplete(isFinal:) never fires, .stopped is never set,
        // and read-aloud does not auto-advance. The final marker must carry audio.
        #expect(
            finals.first.map { $0.frames > 0 } == true,
            "the isFinal chunk has \(finals.first?.frames ?? -1) frames; it must carry audio so its playback completion fires"
        )
    }

    @Test("garbage input does not crash and yields no spurious audio")
    func garbageInputIsHandledGracefully() async throws {
        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        let request = TTSStreamRequest(text: "junk", voice: "alloy", speed: 1.0)
        let stream = decoder.pcmStream()
        let drain = Task<Int, Never> {
            var total = 0
            for await chunk in stream where !chunk.isFinal {
                total += Int(chunk.buffer.frameLength)
            }
            return total
        }
        let junk = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        // May or may not throw parseFailed depending on header luck; must never crash.
        _ = try? await decoder.append(
            TTSChunk.make(request: request, sequenceIndex: 0, data: junk),
            passageId: request.passageId
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        await decoder.finish()
        let frames = await drain.value
        #expect(frames == 0, "random bytes must not decode to real audio frames, got \(frames)")
    }
}
#endif
