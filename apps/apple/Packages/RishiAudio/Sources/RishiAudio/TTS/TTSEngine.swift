import Foundation
import RishiLogging
#if canImport(AVFAudio)
import AVFAudio

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

            pipeTask = Task { [weak self, engine] in
                for await chunk in decoder.pcmStream() {
                    if Task.isCancelled { return }
                    engine.schedule(buffer: chunk) { [weak self] in
                        Task { await self?.onBufferComplete(chunk: chunk) }
                    }
                    await self?.onBufferScheduled(chunk: chunk)
                }
            }

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
        engine.play()
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
            engine.play()
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
#endif
