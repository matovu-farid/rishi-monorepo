import Foundation
import RishiLogging
#if canImport(AVFAudio)
import AVFAudio

private actor ChunkLookup {
    private var table: [PCMChunk.ID: PCMChunk] = [:]
    func record(_ chunk: PCMChunk) { table[chunk.id] = chunk }
    func take(_ id: PCMChunk.ID) -> PCMChunk? { table.removeValue(forKey: id) }
}

/// Orchestrates streamer → decoder → AVAudioEngine for one TTS playback
/// session. Owns the coordination of AudioSessionCoordinator and the
/// observable TTSPlaybackState that SwiftUI binds to.
///
/// Single-session: starting a new request while one is active stops the
/// current session first.
public actor TTSEngine {

    public typealias DecoderFactory = @Sendable (AVAudioFormat) throws -> MP3StreamDecoder

    private let streamer: TTSStreamer
    private let decoderFactory: DecoderFactory
    private let engine: any AudioEngineProtocol
    private let coordinator: AudioSessionCoordinator
    private let state: TTSPlaybackState

    private var pipeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var activeDecoder: MP3StreamDecoder?
    private var firstBufferScheduled = false

    public init(
        streamer: TTSStreamer,
        decoderFactory: @escaping DecoderFactory,
        engine: any AudioEngineProtocol,
        coordinator: AudioSessionCoordinator,
        state: TTSPlaybackState
    ) {
        self.streamer = streamer
        self.decoderFactory = decoderFactory
        self.engine = engine
        self.coordinator = coordinator
        self.state = state
    }

    // MARK: - Public surface

    public func start(request: TTSStreamRequest) async {
        // Tear down any in-flight session.
        await teardown()
        firstBufferScheduled = false

        let observable = state
        await MainActor.run {
            observable.status = .loading
            observable.error = nil
        }
        await coordinator.requestActiveMode(.tts)

        do {
            try engine.attach()
            try engine.start()
            let decoder = try decoderFactory(engine.targetFormat)
            activeDecoder = decoder

            // Local lookup so the engine's completion stream (which yields only
            // PCMChunk.ID) can be resolved back to the original chunk for
            // passageId/isFinal handling. `take` removes the entry, so the table
            // never grows unbounded.
            let chunkLookup = ChunkLookup()
            let inspected = decoder.pcmStream().map { [weak self, chunkLookup] chunk -> PCMChunk in
                await chunkLookup.record(chunk)
                await self?.onBufferScheduled(chunk: chunk)
                return chunk
            }

            pipeTask = Task { [weak self, engine, chunkLookup] in
                for await finishedId in engine.play(inspected) {
                    if Task.isCancelled { return }
                    if let chunk = await chunkLookup.take(finishedId) {
                        await self?.onBufferComplete(chunk: chunk)
                    }
                }
            }

            // KEEP: actor-owned feed loop; consumes mp3 bytes and forwards
            // them to the active decoder actor. No main hop.
            feedTask = Task { [weak self, streamer, request] in
                do {
                    for try await mp3 in streamer.stream(request) {
                        if Task.isCancelled { return }
                        guard let dec = await self?.currentDecoder() else { return }
                        try await dec.append(mp3, passageId: request.passageId)
                    }
                    if let dec = await self?.currentDecoder() {
                        await dec.finish()
                    }
                } catch {
                    await self?.fail(with: error)
                }
            }
        } catch {
            await fail(with: error)
        }
    }

    public func pause() async {
        engine.pause()
        let observable = state
        await MainActor.run { observable.status = .paused }
    }

    public func resume() async {
        engine.resume()
        let observable = state
        await MainActor.run { observable.status = .playing }
    }

    public func stop() async {
        await teardown()
        engine.stop()
        await coordinator.releaseActiveMode(.tts)
        let observable = state
        await MainActor.run { observable.status = .stopped }
    }

    // MARK: - Internals

    private func currentDecoder() -> MP3StreamDecoder? { activeDecoder }

    private func onBufferScheduled(chunk: PCMChunk) async {
        let observable = state
        if !firstBufferScheduled {
            firstBufferScheduled = true
            engine.resume()
            let passageId = chunk.passageId
            await MainActor.run {
                observable.status = .playing
                observable.currentPassageId = passageId
            }
            Log.event("tts.engine.first_buffer", level: .info, data: [
                "passageId": chunk.passageId ?? "",
            ])
        } else if let passageId = chunk.passageId {
            await MainActor.run {
                observable.currentPassageId = passageId
            }
        }
    }

    private func onBufferComplete(chunk: PCMChunk) async {
        if chunk.isFinal {
            // The last buffer drained — release the session.
            engine.stop()
            await coordinator.releaseActiveMode(.tts)
            let observable = state
            await MainActor.run { observable.status = .stopped }
        }
    }

    private func teardown() async {
        // Cancel BOTH tasks first so neither resists the decoder-finish
        // signal, then finish the decoder so its pcmStream() completes,
        // which lets engine.play(_:)'s internal `for try await` exit
        // cleanly. The completions drain in `pipeTask` ends shortly after
        // because the engine's continuation calls `.finish()` when the
        // input ends.
        feedTask?.cancel()
        pipeTask?.cancel()
        feedTask = nil
        pipeTask = nil
        if let decoder = activeDecoder {
            await decoder.finish()
        }
        activeDecoder = nil
    }

    private func fail(with error: Error) async {
        await teardown()
        engine.stop()
        await coordinator.releaseActiveMode(.tts)
        let message = String(describing: error)
        let observable = state
        await MainActor.run {
            observable.status = .error
            observable.error = message
        }
        Log.event("tts.engine.error", level: .error, data: ["error": message])
    }
}

// Phase 29 (29-01): TTSEngine already implements the exact start/pause/resume/
// stop surface ReaderTTSBridge consumes, so conformance is a one-liner with no
// behavioural change — the Phase 23/24 engine internals stay byte-identical.
extension TTSEngine: TTSPlaying {}
#endif
