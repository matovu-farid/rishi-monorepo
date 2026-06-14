import Foundation
import RishiLogging

#if canImport(AudioToolbox) && canImport(AVFAudio)
import AudioToolbox
import AVFAudio

/// Production replacement for Spike C's silent ChunkedMP3Decoder stub.
/// Pipes streamed MP3 bytes into AudioFileStreamOpen for framing, then runs
/// AudioConverter to produce PCM Float32 buffers at the engine output format.
///
/// Usage:
/// ```swift
/// let decoder = try MP3StreamDecoder(targetFormat: engine.outputFormat)
/// Task { for await chunk in decoder.pcmStream() { /* schedule */ } }
/// for try await mp3 in streamer.stream(request) {
///     try await decoder.append(mp3, passageId: request.passageId)
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

    // Packet buffering between AudioFileStream_PacketsProc callback and the
    // converter input callback.
    private var pendingPackets: [Data] = []
    private var pendingDescriptions: [AudioStreamPacketDescription] = []

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
        flushPendingPackets(isFinal: true)
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
        pendingPackets.append(bytes)
        pendingDescriptions.append(contentsOf: descriptions)
        flushPendingPackets(isFinal: false)
    }

    private func flushPendingPackets(isFinal: Bool) {
        guard let converter, let sourceFormat else {
            if isFinal { emitFinalEmpty() }
            return
        }
        guard !pendingPackets.isEmpty || isFinal else { return }
        let totalBytes = pendingPackets.reduce(0) { $0 + $1.count }
        guard totalBytes > 0 else {
            if isFinal { emitFinalEmpty() }
            return
        }
        // Size the buffer so that byteCapacity (= packetCapacity *
        // maximumPacketSize) ALWAYS covers totalBytes. Deriving the capacity
        // purely from the descriptions' count*maxPacketSize can under-allocate
        // (descriptions and the actually-copied bytes can desync), which makes
        // `compressed.byteLength = totalBytes` below trip the AVFoundation
        // assertion `length <= _imp->_byteCapacity` and crash the app. See
        // CompressedBufferSizing for the guaranteed-safe sizing.
        guard let sizing = CompressedBufferSizing.make(
            packetCount: pendingDescriptions.count,
            packetSizes: pendingDescriptions.map(\.mDataByteSize),
            totalBytes: totalBytes
        ) else {
            if isFinal { emitFinalEmpty() }
            return
        }
        let compressed = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: sizing.packetCapacity,
            maximumPacketSize: sizing.maximumPacketSize
        )

        var offset = 0
        let dst = compressed.data.bindMemory(to: UInt8.self, capacity: totalBytes)
        for chunk in pendingPackets {
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(dst.advanced(by: offset), base, chunk.count)
            }
            offset += chunk.count
        }
        compressed.byteLength = UInt32(totalBytes)
        compressed.packetCount = AVAudioPacketCount(pendingDescriptions.count)
        compressed.packetDescriptions?.update(from: pendingDescriptions, count: pendingDescriptions.count)

        pendingPackets.removeAll(keepingCapacity: true)
        pendingDescriptions.removeAll(keepingCapacity: true)

        // Convert compressed → PCM via the pull callback API.
        let outputCapacity = AVAudioFrameCount(Double(targetFormat.sampleRate) * 0.2) // up to 200ms
        guard let pcm = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }
        var error: NSError?
        // Box the one-shot flag + the compressed buffer so the @Sendable
        // converter callback can mutate them without sending-region errors.
        // The actor serialises access; the callback runs synchronously inside
        // converter.convert(to:error:withInputFrom:).
        final class ConvertCarrier: @unchecked Sendable {
            var done = false
            let compressed: AVAudioCompressedBuffer
            init(_ buf: AVAudioCompressedBuffer) { self.compressed = buf }
        }
        let carrier = ConvertCarrier(compressed)
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if carrier.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            carrier.done = true
            outStatus.pointee = .haveData
            return carrier.compressed
        }
        if status == .error {
            Log.event("tts.decoder.convert_error", level: .error, data: [
                "error": error?.localizedDescription ?? "unknown",
            ])
            return
        }
        if pcm.frameLength > 0 {
            continuation.yield(PCMChunk(buffer: pcm, passageId: pendingPassageId, isFinal: isFinal))
        } else if isFinal {
            emitFinalEmpty()
        }
    }

    private func emitFinalEmpty() {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 1) else { return }
        buffer.frameLength = 0
        continuation.yield(PCMChunk(buffer: buffer, passageId: pendingPassageId, isFinal: true))
    }
}
#endif
