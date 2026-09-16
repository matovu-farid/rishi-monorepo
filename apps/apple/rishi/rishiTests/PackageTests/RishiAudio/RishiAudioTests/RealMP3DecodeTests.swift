@testable import rishi
import Testing
import Foundation


#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import AudioToolbox

/// Lower-seam coverage: a REAL MP3 (not a 4-byte sentinel) must decode through
/// `MP3StreamDecoder` and yield at least one non-empty PCM frame. Before the
/// in-progress `CompressedBufferSizing` crash guard (RESEARCH 3.4), a real
/// decode would have tripped the AVFoundation `length <= _byteCapacity`
/// assertion; passing this test confirms the guard works against a real decode,
/// not just the synthetic fuzz in `CompressedBufferSizingTests`.
@Suite("Real MP3 decode", .serialized)
struct RealMP3DecodeTests {

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

    @Test("real MP3 decodes to at least one non-empty PCM frame")
    func realMP3YieldsNonEmptyPCM() async throws {
        let mp3 = try loadFixtureMP3()
        #expect(mp3.count > 1000, "fixture must be a real MP3, not an error body")

        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        let stream = decoder.pcmStream()

        // Drain the PCM stream on a background task, accumulating total frames
        // and tracking whether a final marker arrives.
        let drain = Task<(frames: Int, sawFinal: Bool), Never> {
            var total = 0
            var sawFinal = false
            for await chunk in stream {
                total += Int(chunk.buffer.frameLength)
                if chunk.isFinal { sawFinal = true }
            }
            return (total, sawFinal)
        }

        // AudioFileStream parses on its own thread and re-enters the actor via
        // `Task { await ... }` hops (see MP3StreamDecoder.openStream). Those
        // packet-handling Tasks are queued behind this call, so feed the bytes
        // in slices with cooperative yields between them — mirroring the real
        // streamed feed — to let the parser callbacks drain into the converter
        // before we finish(). A single append+finish would race the callbacks
        // and flush an empty packet buffer.
        let sliceSize = 4096
        var index = 0
        while index < mp3.count {
            let end = min(index + sliceSize, mp3.count)
            try await decoder.append(mp3.subdata(in: index..<end), passageId: "0")
            index = end
            await Task.yield()
        }
        // Give the trailing parse callbacks time to enqueue their packets
        // before we flush on finish().
        try? await Task.sleep(nanoseconds: 200_000_000)
        await decoder.finish()

        let result = await drain.value
        #expect(result.frames > 0, "a real MP3 must decode to non-empty PCM frames")
        #expect(result.sawFinal, "decoder must emit a final marker after finish()")
    }
}
#endif
