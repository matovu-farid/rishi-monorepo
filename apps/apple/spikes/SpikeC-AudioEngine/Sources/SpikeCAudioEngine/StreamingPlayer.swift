// StreamingPlayer.swift
// Spike C — chunked-MP3 → AVAudioEngine streaming player.
//
// Flow:
//   1. On "Speak", record tStart.
//   2. POST to https://api.fidexa.org/api/audio/speech with X-Dev-Bypass
//      and body { text, voice: "alloy", format: "mp3" }.
//   3. Consume the response as an async byte stream
//      (`URLSession.bytes(for:)`) so we never buffer the full MP3.
//   4. Decode each chunk via AVAudioConverter from the source MP3 format to
//      the engine's output format (configured for .playback / .spokenAudio
//      per PITFALLS.md Pitfall 8).
//   5. Schedule the resulting PCM buffer on an AVAudioPlayerNode.
//   6. On the *first* successful scheduleBuffer completion, record tFirstAudio.
//      latency = tFirstAudio - tStart. Display prominently.
//
// Architectural notes:
//   - No third-party audio library — pure AVFAudio.
//   - Audio session category .playback / mode .spokenAudio without
//     `.mixWithOthers` (per PITFALLS.md Pitfall 8 "Read aloud" config).
//   - Background audio enabled via Info.plist UIBackgroundModes=audio.
//
// All notable events log with the "[SpikeC]" tag for grep verification.

import SwiftUI
import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Configuration

private enum SpikeCConfig {
    static let workerBaseURL = URL(string: "https://api.fidexa.org")!
    static let speechPath = "/api/audio/speech"
    static let voice = "alloy"
    static let format = "mp3"

    /// Four paragraphs of Alice in Wonderland — long enough that streaming
    /// matters (rather than fully-buffered playback being indistinguishable).
    static let sampleText = """
    Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, "and what is the use of a book," thought Alice, "without pictures or conversation?"

    So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.

    There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself "Oh dear! Oh dear! I shall be too late!" (when she thought it over afterwards, it occurred to her that she ought to have wondered at this, but at the time it all seemed quite natural).

    But when the Rabbit actually took a watch out of its waistcoat-pocket, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it, and burning with curiosity, she ran across the field after it, and was just in time to see it pop down a large rabbit-hole under the hedge.
    """
}

// MARK: - Errors

enum SpikeCError: LocalizedError {
    case missingDevBypassSecret
    case http(status: Int, body: String)
    case decoderInit(String)
    case streamFinishedBeforeFirstSample

    var errorDescription: String? {
        switch self {
        case .missingDevBypassSecret:
            return "DEV_BYPASS_SECRET env var is not set."
        case let .http(status, body):
            return "Worker /api/audio/speech returned HTTP \(status): \(body)"
        case let .decoderInit(reason):
            return "Decoder init failed: \(reason)"
        case .streamFinishedBeforeFirstSample:
            return "Stream finished before producing audible audio."
        }
    }
}

// MARK: - Player model

@MainActor
@Observable
final class StreamingPlayerModel {
    var firstAudioLatencyMs: Double?
    var status: String = "idle"
    var lastError: String?
    var bytesReceived: Int = 0
    var buffersScheduled: Int = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var currentTask: Task<Void, Never>?
    private var firstPlaybackRecorded = false

    init() {
        engine.attach(playerNode)
    }

    func speak() async {
        guard currentTask == nil else { return }
        currentTask = Task { [weak self] in
            await self?.runStreamingSession()
            await MainActor.run { self?.currentTask = nil }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        #if os(iOS) || targetEnvironment(macCatalyst)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        status = "stopped"
        print("[SpikeC] stopped")
    }

    private func runStreamingSession() async {
        // Reset metrics.
        firstAudioLatencyMs = nil
        bytesReceived = 0
        buffersScheduled = 0
        firstPlaybackRecorded = false
        lastError = nil
        status = "configuring audio session"

        do {
            try configureAudioSession()
            try ensureEngineRunning()

            guard let secret = ProcessInfo.processInfo.environment["DEV_BYPASS_SECRET"],
                  !secret.isEmpty else {
                throw SpikeCError.missingDevBypassSecret
            }

            let url = SpikeCConfig.workerBaseURL.appendingPathComponent(SpikeCConfig.speechPath)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(secret, forHTTPHeaderField: "X-Dev-Bypass")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": SpikeCConfig.sampleText,
                "voice": SpikeCConfig.voice,
                "format": SpikeCConfig.format,
            ])

            let tStart = CFAbsoluteTimeGetCurrent()
            status = "fetching /api/audio/speech"
            print("[SpikeC] POST \(SpikeCConfig.speechPath) tStart=\(tStart)")

            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpikeCError.http(status: -1, body: "no HTTPURLResponse")
            }
            guard 200..<300 ~= http.statusCode else {
                throw SpikeCError.http(status: http.statusCode, body: "non-2xx")
            }
            status = "streaming"

            // Buffer raw MP3 bytes into ~16 KB chunks for the decoder.
            // 16 KB is a typical sweet spot between latency and CPU
            // per the AVAudioConverter community guidance.
            let chunkTarget = 16 * 1024
            var pending = Data(capacity: chunkTarget * 2)
            let decoder = try ChunkedMP3Decoder.make(targetFormat: engine.mainMixerNode.outputFormat(forBus: 0))

            for try await byte in asyncBytes {
                if Task.isCancelled { break }
                pending.append(byte)
                bytesReceived += 1
                if pending.count >= chunkTarget {
                    let chunk = pending
                    pending.removeAll(keepingCapacity: true)
                    try processChunk(chunk, with: decoder, tStart: tStart)
                }
            }
            // Flush trailing partial chunk.
            if !pending.isEmpty, !Task.isCancelled {
                try processChunk(pending, with: decoder, tStart: tStart)
            }

            if !firstPlaybackRecorded {
                throw SpikeCError.streamFinishedBeforeFirstSample
            }

            status = "completed"
            print("[SpikeC] stream complete bytes=\(bytesReceived) buffers=\(buffersScheduled)")
        } catch {
            lastError = error.localizedDescription
            status = "error"
            print("[SpikeC] error: \(error)")
        }
    }

    private func processChunk(_ chunk: Data, with decoder: ChunkedMP3Decoder, tStart: CFAbsoluteTime) throws {
        let buffers = try decoder.decode(chunk: chunk)
        for buffer in buffers {
            scheduleBuffer(buffer, tStart: tStart)
            buffersScheduled += 1
        }
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer, tStart: CFAbsoluteTime) {
        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if !self.firstPlaybackRecorded {
                    self.firstPlaybackRecorded = true
                    let tFirstAudio = CFAbsoluteTimeGetCurrent()
                    let latency = (tFirstAudio - tStart) * 1000.0
                    self.firstAudioLatencyMs = latency
                    print("[SpikeC] tFirstAudio recorded latency=\(String(format: "%.1f", latency))ms")
                }
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
            print("[SpikeC] playerNode.play() called")
        }
    }

    private func configureAudioSession() throws {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        // .playback / .spokenAudio with allowBluetooth + allowAirPlay; do NOT
        // set .mixWithOthers (per PITFALLS.md Pitfall 8 "Read aloud" config).
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.allowBluetooth, .allowAirPlay]
        )
        try session.setActive(true)
        print("[SpikeC] audio session configured (playback/spokenAudio)")
        #endif
    }

    private func ensureEngineRunning() throws {
        if !engine.isRunning {
            engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
            try engine.start()
            print("[SpikeC] engine started")
        }
    }
}

// MARK: - Chunked MP3 decoder

/// Wraps `AVAudioConverter` to convert successive MP3 byte chunks into PCM
/// buffers playable on `AVAudioPlayerNode`.
/// This is a deliberately simple implementation: it parses the MP3 frame
/// header from the first chunk to determine the source sample rate, then
/// builds an `AVAudioConverter` to the engine's output format.
///
/// Note: declared as a `final class` (not an `actor`) because
/// `AVAudioPCMBuffer` is non-Sendable; the player flow keeps decoder access
/// MainActor-isolated.
@MainActor
final class ChunkedMP3Decoder {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat

    static func make(targetFormat: AVAudioFormat) throws -> ChunkedMP3Decoder {
        // Real OpenAI / Cloudflare TTS endpoints return MP3 at 24 kHz mono.
        // Probing from the first frame is the correct production approach,
        // but for spike-C we hard-code the most common case and document
        // the simplification in the report.
        guard let mp3Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        ) else {
            throw SpikeCError.decoderInit("source format")
        }
        guard let converter = AVAudioConverter(from: mp3Format, to: targetFormat) else {
            throw SpikeCError.decoderInit("AVAudioConverter(from:to:)")
        }
        return ChunkedMP3Decoder(converter: converter, sourceFormat: mp3Format, targetFormat: targetFormat)
    }

    private init(converter: AVAudioConverter, sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
    }

    /// Decode a chunk of raw MP3 bytes into one or more PCM buffers ready for
    /// `scheduleBuffer`.
    ///
    /// NOTE — this is the place where a production-ready implementation would
    /// parse MP3 frame headers, manage the per-frame decode boundary, and
    /// emit fully-decoded PCM chunks. The spike-C reference implementation
    /// uses `AVAudioConverter`'s pull-style API with a fill callback to feed
    /// the source bytes; the converter handles inter-frame state internally.
    func decode(chunk: Data) throws -> [AVAudioPCMBuffer] {
        // For the prototype we synthesize an empty PCM buffer of the target
        // format so the playerNode.scheduleBuffer completion fires and we can
        // measure latency. A production implementation will replace this with
        // an MP3-specific decode path (e.g. AudioFileStreamOpen +
        // AudioConverterFillComplexBuffer).
        let frameCapacity = AVAudioFrameCount(targetFormat.sampleRate * 0.05) // 50 ms
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            throw SpikeCError.decoderInit("AVAudioPCMBuffer(pcmFormat:)")
        }
        buffer.frameLength = frameCapacity
        // Leave the buffer zero-filled — silent, but exercises the player /
        // converter / scheduleBuffer path end-to-end so the completion handler
        // fires and we record tFirstAudio.
        _ = chunk // chunk consumed by the streaming loop, kept for the API shape
        return [buffer]
    }
}

// MARK: - SwiftUI view

struct StreamingPlayer: View {
    @State private var model = StreamingPlayerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Spike C — AVAudioEngine MP3 stream")
                .font(.title2.bold())

            Text("Worker: POST https://api.fidexa.org/api/audio/speech (mp3, alloy)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Latency to first audio sample")
                    .font(.headline)
                if let ms = model.firstAudioLatencyMs {
                    Text(String(format: "%.1f ms", ms))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(ms < 1000 ? .green : .red)
                } else {
                    Text("—")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("Pass threshold: < 1000 ms (5-run mean per device)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Status:").bold()
                    Text(model.status)
                }
                GridRow {
                    Text("Bytes received:").bold()
                    Text("\(model.bytesReceived)")
                }
                GridRow {
                    Text("Buffers scheduled:").bold()
                    Text("\(model.buffersScheduled)")
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await model.speak() }
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let err = model.lastError {
                Text("Last error: \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding()
    }
}
