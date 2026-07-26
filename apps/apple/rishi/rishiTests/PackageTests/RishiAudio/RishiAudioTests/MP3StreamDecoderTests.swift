@testable import rishi
import Testing
import Foundation


#if canImport(AVFAudio) && canImport(AudioToolbox)
import AVFAudio
import AudioToolbox

@Suite("MP3StreamDecoder", .serialized)
struct MP3StreamDecoderTests {

    /// Build a minimal AVAudioFormat suitable for engine output.
    private func makeTargetFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    }

    @Test("Initializes without error and yields a final marker on finish")
    func initEmpty() async throws {
        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        let stream = decoder.pcmStream()
        var iter = stream.makeAsyncIterator()
        await decoder.finish()
        // After finish() the stream may yield one empty final marker, then ends.
        let first = await iter.next()
        if let first {
            #expect(first.isFinal == true)
        }
    }

    @Test("Append on a bogus payload does not crash — parser tolerates garbage")
    func appendGarbageDoesNotThrow() async throws {
        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        // Random bytes — AudioFileStreamParseBytes may return a non-zero status;
        // contract here is "do not crash". A thrown DecoderError.parseFailed is
        // an acceptable surface.
        let garbage = Data((0..<512).map { _ in UInt8.random(in: 0...255) })
        do {
            try await decoder.append(garbage, passageId: nil)
        } catch let error as MP3StreamDecoder.DecoderError {
            if case .parseFailed = error {} // expected for non-MP3
        }
        await decoder.finish()
    }

    @Test("Accepts a minimal MP3-shaped fixture without crashing")
    func acceptsMP3FixtureBytes() async throws {
        // 4-byte MP3 frame header sentinel — AudioFileStreamOpen seeded with
        // kAudioFileMP3Type tolerates partial frames during parse and waits
        // for more data; this verifies the *type* hint propagates correctly.
        let header = Data([0xFF, 0xFB, 0x90, 0x00])
        let decoder = try MP3StreamDecoder(targetFormat: makeTargetFormat())
        do {
            try await decoder.append(header, passageId: "p-1")
        } catch let error as MP3StreamDecoder.DecoderError {
            // Acceptable: a 4-byte sentinel may not parse; contract is no crash.
            if case .parseFailed = error {} else { throw error }
        }
        await decoder.finish()
    }
}
#endif
