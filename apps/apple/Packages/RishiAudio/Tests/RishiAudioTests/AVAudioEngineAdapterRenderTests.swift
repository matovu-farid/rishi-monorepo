import Testing
import Foundation
@testable import RishiAudio

#if canImport(AVFAudio)
import AVFAudio

/// Drives the REAL AVAudioEngineAdapter through offline manual rendering so we
/// can observe whether the player node actually produces audio. The
/// FakeAudioEngine cannot reproduce the next/prev "shows Playing but silent"
/// bug because it never renders; this does.
///
/// The reader's prev/next/repeat path interrupts a PLAYING passage mid-stream
/// (ReaderTTSBridge.jump -> engine.stop() while audio is in flight), then starts
/// the next passage. Auto-advance never hits this — it lets each passage finish
/// naturally. This suite renders passage 1, stops mid-stream, plays passage 2,
/// and asserts passage 2 is NOT silent.
@Suite("AVAudioEngineAdapter offline render", .serialized)
struct AVAudioEngineAdapterRenderTests {

    private func sineChunk(format: AVAudioFormat, frames: AVAudioFrameCount, passageId: String) -> PCMChunk {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        for c in 0..<channels {
            if let ptr = buffer.floatChannelData?[c] {
                for i in 0..<Int(frames) {
                    ptr[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate)) * 0.5
                }
            }
        }
        return PCMChunk(buffer: buffer, passageId: passageId, isFinal: false)
    }

    private func stream(_ chunks: [PCMChunk]) -> AsyncStream<PCMChunk> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private func renderPeak(_ adapter: AVAudioEngineAdapter, totalFrames: AVAudioFrameCount) throws -> Float {
        let format = adapter.manualRenderingFormat
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var peak: Float = 0
        var remaining = totalFrames
        while remaining > 0 {
            let n = min(remaining, 4096)
            let status = try adapter.renderOffline(n, to: out)
            let channels = Int(format.channelCount)
            for c in 0..<channels {
                if let ptr = out.floatChannelData?[c] {
                    for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ptr[i])) }
                }
            }
            if status == .error { break }
            remaining -= n
        }
        return peak
    }

    @Test("re-playing after a mid-stream stop still renders audio")
    func midStreamStopThenPlayRendersAudio() async throws {
        let adapter = AVAudioEngineAdapter()
        try adapter.attach()
        let format = adapter.targetFormat
        try adapter.enableOfflineRendering(format: format, maximumFrameCount: 4096)
        try adapter.start()

        // Passage 1: consume the play() stream (that's what triggers buffer
        // scheduling — TTSEngine's pipeTask does this), play, render.
        let p1 = adapter.play(stream((0..<4).map { _ in sineChunk(format: format, frames: 2048, passageId: "0") }))
        let c1 = Task { for await _ in p1 {} }
        adapter.resume()
        try await Task.sleep(nanoseconds: 100_000_000)
        let peak1 = try renderPeak(adapter, totalFrames: 8192)
        #expect(peak1 > 0.01, "passage 1 must render audio (peak \(peak1))")
        c1.cancel()

        // Mid-stream stop (what prev/next/repeat does), then play passage 2.
        adapter.stop()
        try adapter.attach()
        try adapter.start()
        let p2 = adapter.play(stream((0..<4).map { _ in sineChunk(format: format, frames: 2048, passageId: "1") }))
        let c2 = Task { for await _ in p2 {} }
        adapter.resume()
        try await Task.sleep(nanoseconds: 100_000_000)
        let peak2 = try renderPeak(adapter, totalFrames: 8192)
        #expect(peak2 > 0.01, "after a mid-stream stop, re-playing must still render audio — got peak \(peak2) (the next/prev silence bug)")
        c2.cancel()

        adapter.stop()
    }
}
#endif
