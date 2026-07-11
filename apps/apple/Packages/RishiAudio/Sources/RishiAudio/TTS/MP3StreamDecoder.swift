import Foundation
import RishiLogging

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AudioToolbox
import AVFAudio

/// Production replacement for Spike C's silent ChunkedMP3Decoder stub.
/// Pipes streamed MP3 chunks into AudioFileStreamOpen for framing, then runs
/// AudioConverter to produce PCM Float32 buffers at the engine output format.
///
/// Usage:
/// ```swift
/// let decoder = try MP3StreamDecoder(targetFormat: engine.outputFormat)
/// Task { for await chunk in decoder.pcmStream() { /* schedule */ } }
/// for try await mp3Chunk in streamer.stream(request) {
///     try await decoder.append(mp3Chunk, passageId: request.passageId)
/// }
/// await decoder.finish()
/// ```
///
/// Implementation note: AudioFileStreamID and AudioConverterRef are raw
/// pointers Swift does not know how to mark Sendable. Mutating access is
/// serialised by the actor; the C callbacks bridge back to the actor via
/// `Unmanaged.passUnretained(self).toOpaque()` and re-enter via a `Task`.
public actor MP3StreamDecoder {

    public enum DecoderError: Error, Equatable {
        case openFailed(OSStatus)
        case parseFailed(OSStatus)
        case converterInit
        case missingDataFormat
    }

    private let targetFormat: AVAudioFormat
    // nonisolated(unsafe) because (a) AudioFileStreamID is a raw OpaquePointer,
    // (b) the field is written exactly once during init before any other actor
    // method can run, and (c) reads happen only inside actor-isolated methods
    // or the actor's own deinit. The actor provides the serialisation.
    private nonisolated(unsafe) var streamID: AudioFileStreamID?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let continuation: AsyncStream<PCMChunk>.Continuation
    private let stream: AsyncStream<PCMChunk>
    private var pendingPassageId: String?
    private var finished = false

    // Compressed MP3 packet batches awaiting decode. One entry per
    // AudioFileStream packets callback; the bytes and their batch-relative
    // packet descriptions are kept together so the descriptions' mStartOffset
    // values stay aligned with the bytes when we build the per-batch
    // AVAudioCompressedBuffer at drain time. Concatenating blobs from different
    // callbacks into one buffer (the previous design) desynced offsets and
    // truncated playback to the first output buffer.
    private var batches: [(bytes: Data, descs: [AudioStreamPacketDescription])] = []

    // One-chunk lookahead. We hold back the most recently produced PCM chunk so
    // that on finish() the LAST real-audio chunk can be re-stamped `isFinal`.
    // The terminal marker must carry audio: a 0-frame final buffer's
    // AVAudioPlayerNode completion is unreliable, so the engine would never see
    // the passage finish (`onBufferComplete(isFinal:)`), never set `.stopped`,
    // and read-aloud would not auto-advance.
    private var heldChunk: PCMChunk?

    public init(targetFormat: AVAudioFormat) throws {
        self.targetFormat = targetFormat
        var local: AsyncStream<PCMChunk>.Continuation!
        self.stream = AsyncStream { local = $0 }
        self.continuation = local
        // openStream is nonisolated — sets up the C-bridge before any actor
        // state mutation, then writes the resulting AudioFileStreamID into
        // self.streamID. Safe to call from the synchronous init body.
        self.streamID = try Self.openStream(context: self)
    }

    deinit {
        if let streamID {
            AudioFileStreamClose(streamID)
        }
        continuation.finish()
    }

    public nonisolated func pcmStream() -> AsyncStream<PCMChunk> { stream }

    /// Push streamed MP3 bytes into the parser. Safe to call from any actor.
    public func append(_ chunk: TTSChunk, passageId: String?) throws {
        try append(chunk.data, passageId: passageId)
    }

    public func append(_ data: Data, passageId: String?) throws {
        guard let streamID, !finished else { return }
        pendingPassageId = passageId
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(streamID, UInt32(data.count), base, [])
        }
        if status != noErr {
            throw DecoderError.parseFailed(status)
        }
    }

    /// Tell the parser no more bytes are coming; flush remaining packets and
    /// close the output stream after the last PCMChunk yields.
    public func finish() {
        finished = true
        drain(isFinal: true)
        continuation.finish()
    }

    // MARK: - AudioFileStream wiring

    private static func openStream(context owner: MP3StreamDecoder) throws -> AudioFileStreamID? {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(owner).toOpaque())
        var id: AudioFileStreamID?
        let status = AudioFileStreamOpen(
            context,
            { ctx, _, propertyID, _ in
                let me = Unmanaged<MP3StreamDecoder>.fromOpaque(ctx).takeUnretainedValue()
                // KEEP: AudioFileStream C callback fires off the calling thread
                // (decoder runs on its own queue); Task hops into the
                // MP3StreamDecoder actor to process the property change.
                Task { await me.handleProperty(propertyID) }
            },
            { ctx, byteCount, packetCount, data, descriptions in
                let me = Unmanaged<MP3StreamDecoder>.fromOpaque(ctx).takeUnretainedValue()
                // Copy bytes + descriptions out of the callback-owned memory.
                let bytes = Data(bytes: data, count: Int(byteCount))
                let descs: [AudioStreamPacketDescription]
                if let descriptions {
                    descs = (0..<Int(packetCount)).map { i in descriptions[i] }
                } else {
                    descs = []
                }
                // KEEP: AudioFileStream C callback; Task hops into the actor
                // to enqueue the packet copy. No main-bound work.
                Task { await me.handlePackets(bytes: bytes, descriptions: descs) }
            },
            kAudioFileMP3Type,
            &id
        )
        if status != noErr { throw DecoderError.openFailed(status) }
        return id
    }

    fileprivate func handleProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard let streamID else { return }
        switch propertyID {
        case kAudioFileStreamProperty_DataFormat:
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: asbd))
            let status = AudioFileStreamGetProperty(
                streamID,
                kAudioFileStreamProperty_DataFormat,
                &size,
                &asbd
            )
            if status == noErr, let avFormat = AVAudioFormat(streamDescription: &asbd) {
                self.sourceFormat = avFormat
                self.converter = AVAudioConverter(from: avFormat, to: targetFormat)
                if self.converter == nil {
                    Log.event("tts.decoder.converter_init_failed", level: .error, data: [:])
                }
            }
        case kAudioFileStreamProperty_ReadyToProducePackets:
            Log.event("tts.decoder.ready", level: .info, data: [:])
        default:
            break
        }
    }

    fileprivate func handlePackets(bytes: Data, descriptions: [AudioStreamPacketDescription]) {
        guard !bytes.isEmpty, !descriptions.isEmpty else { return }
        batches.append((bytes, descriptions))
        drain(isFinal: false)
    }

    /// Decode every queued compressed batch into PCM, in order, yielding ALL
    /// produced buffers (not just the first). The previous design capped output
    /// at a single ~200ms buffer per batch and dropped the remainder, which on
    /// device played "the first word" then stopped.
    private func drain(isFinal: Bool) {
        guard let converter, let sourceFormat else {
            // Format/converter not ready yet (the DataFormat property callback
            // can land after the first packets callback via the actor Task
            // hops). Leave the batches queued; a later drain processes them in
            // order. On a final drain with no converter there is nothing to do.
            if isFinal { emitFinalMarker() }
            return
        }

        // Build one AVAudioCompressedBuffer per queued batch. Each batch's
        // packet descriptions are relative to that batch's own bytes, so a
        // dedicated buffer per batch keeps mStartOffset aligned. Drop any batch
        // we cannot describe (guards the "bytes provided but 0 packet
        // descriptions" converter error seen on device).
        var queue: [AVAudioCompressedBuffer] = []
        queue.reserveCapacity(batches.count)
        for batch in batches {
            if let compressed = makeCompressedBuffer(batch: batch, sourceFormat: sourceFormat) {
                queue.append(compressed)
            }
        }
        batches.removeAll(keepingCapacity: true)

        guard !queue.isEmpty else {
            if isFinal { emitFinalMarker() }
            return
        }

        // Pull-convert loop: the converter calls the input block as needed; we
        // vend queued compressed buffers in order, then signal end-of-input.
        // We keep filling fresh PCM buffers until the converter has consumed all
        // queued input (.inputRanDry) or, when final, flushed (.endOfStream).
        // Box the cursor so the @Sendable input block can advance it; the actor
        // serialises access and the block runs synchronously inside convert().
        final class InputCursor: @unchecked Sendable {
            var index = 0
            let buffers: [AVAudioCompressedBuffer]
            let isFinal: Bool
            init(_ buffers: [AVAudioCompressedBuffer], isFinal: Bool) {
                self.buffers = buffers
                self.isFinal = isFinal
            }
        }
        let cursor = InputCursor(queue, isFinal: isFinal)

        let outputCapacity = AVAudioFrameCount(Double(targetFormat.sampleRate) * 0.5) // 0.5s per pull
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { break }
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, outStatus in
                if cursor.index < cursor.buffers.count {
                    let next = cursor.buffers[cursor.index]
                    cursor.index += 1
                    outStatus.pointee = .haveData
                    return next
                }
                outStatus.pointee = cursor.isFinal ? .endOfStream : .noDataNow
                return nil
            }

            if status == .error {
                Log.event("tts.decoder.convert_error", level: .error, data: [
                    "error": error?.localizedDescription ?? "unknown",
                ])
                break
            }

            if pcm.frameLength > 0 {
                // Hold the newest chunk back by one; emit the previously held
                // chunk as non-final. The final held chunk becomes the isFinal
                // marker in the finish() branch below.
                if let previous = heldChunk {
                    continuation.yield(previous)
                }
                heldChunk = PCMChunk(buffer: pcm, passageId: pendingPassageId, isFinal: false)
            }

            // .haveData means more output may remain for the same input — keep
            // pulling. Any other status (.inputRanDry / .endOfStream) means the
            // queued input is exhausted; stop. Guard against a no-progress spin.
            if status != .haveData { break }
            if pcm.frameLength == 0 && cursor.index >= cursor.buffers.count { break }
        }

        if isFinal { emitFinalMarker() }
    }

    /// Emit the terminal `isFinal` chunk. Prefer re-stamping the last held real
    /// chunk (so the marker carries audio and its playback completion reliably
    /// fires); fall back to a 0-frame marker only when no audio was decoded
    /// (empty/garbage input).
    private func emitFinalMarker() {
        if let last = heldChunk {
            heldChunk = nil
            continuation.yield(PCMChunk(buffer: last.buffer, passageId: last.passageId, isFinal: true))
        } else {
            emitFinalEmpty()
        }
    }

    /// Build a compressed buffer for a single parser batch, or nil if it cannot
    /// be safely described (no bytes, no descriptions, or the source format does
    /// not expose packet descriptions for this VBR stream).
    private func makeCompressedBuffer(
        batch: (bytes: Data, descs: [AudioStreamPacketDescription]),
        sourceFormat: AVAudioFormat
    ) -> AVAudioCompressedBuffer? {
        let totalBytes = batch.bytes.count
        guard totalBytes > 0, !batch.descs.isEmpty else { return nil }

        // Size so byteCapacity (= packetCapacity * maximumPacketSize) always
        // covers totalBytes; setting byteLength beyond capacity trips an
        // AVFoundation assertion and crashes. See CompressedBufferSizing.
        guard let sizing = CompressedBufferSizing.make(
            packetCount: batch.descs.count,
            packetSizes: batch.descs.map(\.mDataByteSize),
            totalBytes: totalBytes
        ) else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: sizing.packetCapacity,
            maximumPacketSize: sizing.maximumPacketSize
        )

        let dst = compressed.data.bindMemory(to: UInt8.self, capacity: totalBytes)
        batch.bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(dst, base, totalBytes)
        }
        compressed.byteLength = UInt32(totalBytes)
        compressed.packetCount = AVAudioPacketCount(batch.descs.count)

        guard let packetDescriptions = compressed.packetDescriptions else {
            // VBR MP3 requires per-packet descriptions; without them the
            // converter rejects the input ("bytes provided but packet
            // descriptions (0) only account for 0 bytes"). Drop rather than feed
            // a buffer that would stall the converter.
            Log.event("tts.decoder.no_packet_descriptions", level: .error, data: [:])
            return nil
        }
        packetDescriptions.update(from: batch.descs, count: batch.descs.count)
        return compressed
    }

    private func emitFinalEmpty() {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1) else { return }
        buffer.frameLength = 0
        continuation.yield(PCMChunk(buffer: buffer, passageId: pendingPassageId, isFinal: true))
    }
}
#endif
