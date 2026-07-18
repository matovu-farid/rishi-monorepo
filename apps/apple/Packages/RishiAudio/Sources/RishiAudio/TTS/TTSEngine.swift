import Foundation
import RishiLogging

#if canImport(AVFAudio)
    import AVFAudio

    private actor ChunkLookup {
        private var table: [PCMChunk.ID: PCMChunk] = [:]
        func record(_ chunk: PCMChunk) { table[chunk.id] = chunk }
        func take(_ id: PCMChunk.ID) -> PCMChunk? {
            table.removeValue(forKey: id)
        }
    }

    /// Orchestrates streamer → decoder → AVAudioEngine for one TTS playback
    /// session. Owns the coordination of AudioSessionCoordinator and the
    /// observable TTSPlaybackState that SwiftUI binds to.
    ///
    /// Single-session: starting a new request while one is active stops the
    /// current session first.
    public actor TTSEngine {

        public typealias DecoderFactory =
            @Sendable (AVAudioFormat) throws -> MP3StreamDecoder

        private let streamer: TTSStreamer
        private let decoderFactory: DecoderFactory
        private let engine: any AudioEngineProtocol
        private let coordinator: AudioSessionCoordinator
        private let state: TTSPlaybackState

        private var pipeTask: Task<Void, Never>?
        private var feedTask: Task<Void, Never>?
        private var activeDecoder: MP3StreamDecoder?
        private var firstBufferScheduled = false
        /// Long-lived-engine flag. The FIRST passage of a read-aloud session brings
        /// the engine up (attach + start + session activate); every subsequent
        /// passage switch only resets the player node — no attach/start/stop, no
        /// session churn. Cleared in stop()/fail() (the only paths that tear the
        /// engine down).
        private var engineRunning = false
        private var playbackGeneration = 0
        private var didStartForGeneration = 0
        private var settledGeneration = 0
        private var pendingResult: Result<Void, Error>?
        private var waiter: CheckedContinuation<Void, Error>?

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
            settle(.failure(CancellationError()), generation: playbackGeneration)
            playbackGeneration += 1
            didStartForGeneration = 0
            pendingResult = nil
            if let existing = waiter {
                waiter = nil
                existing.resume(throwing: CancellationError())
            }
            firstBufferScheduled = false
            // Always leave `.stopped` before returning, including cache hits.
            // Speak completion uses waitUntilFinished, not residual status.
            let observable = state
            await MainActor.run {
                observable.error = nil
                observable.update(status: .loading)
            }
            // Single-audio-owner invariant: let the coordinator stop us if another
            // owner (voice) takes the session. stop() is our full teardown and
            // releases .tts itself, so this is safe to call any time.

            // No-op on a switch: an already-active .tts coordinator reduces this to
            // .switchPassage, which the policy returns [] for (no configure/activate).

            do {
                // Long-lived engine: bring it up ONCE (first passage), then only
                // reset the player node on every switch/auto-advance — no
                // attach/start/stop and no session churn mid-session.
                if !engineRunning {
                    try engine.attach()
                    try engine.start()
                    engineRunning = true
                } else {
                    engine.resetPlayerNode()
                }
                let decoder = try decoderFactory(engine.targetFormat)
                activeDecoder = decoder

                // Local lookup so the engine's completion stream (which yields only
                // PCMChunk.ID) can be resolved back to the original chunk for
                // passageId/isFinal handling. `take` removes the entry, so the table
                // never grows unbounded.
                let chunkLookup = ChunkLookup()
                let inspected = decoder.pcmStream().map {
                    [weak self, chunkLookup] chunk -> PCMChunk in
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
                        for try await chunk in await streamer.stream(request) {
                            if Task.isCancelled { return }
                            guard let dec = await self?.currentDecoder() else {
                                return
                            }
                            try await dec.append(
                                chunk,
                                passageId: request.passageId
                            )
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

        }

        public func resume() async {
            engine.resume()
        }

        public func stop() async {
            // The ONLY place the long-lived engine is torn down + session released.
            await teardown()
            engine.stop()
            engineRunning = false
            await coordinator.releaseActiveMode(.tts)
            settle(.failure(CancellationError()), generation: playbackGeneration)
        }

        public func waitUntilFinished() async throws {
            if let pending = pendingResult {
                pendingResult = nil
                try pending.get()
                return
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if let existing = waiter {
                    waiter = continuation
                    existing.resume(throwing: CancellationError())
                    return
                }
                if let pending = pendingResult {
                    pendingResult = nil
                    continuation.resume(with: pending)
                    return
                }
                waiter = continuation
            }
        }

        // MARK: - Internals

        private func currentDecoder() -> MP3StreamDecoder? { activeDecoder }

        private func settle(_ result: Result<Void, Error>, generation: Int) {
            guard generation == playbackGeneration else { return }
            guard settledGeneration != generation else { return }
            settledGeneration = generation
            if let waiter {
                self.waiter = nil
                pendingResult = nil
                waiter.resume(with: result)
            } else {
                pendingResult = result
            }
        }

        private func onBufferScheduled(chunk: PCMChunk) async {
            let observable = state
            if await state.status == .paused {
                return
            }
            if !firstBufferScheduled {
                firstBufferScheduled = true
                didStartForGeneration = playbackGeneration
                engine.resume()
                let passageId = chunk.passageId
                await MainActor.run {
                    observable.update(status: .playing)
                    observable.currentPassageId = passageId
                }
                Log.event(
                    "tts.engine.first_buffer",
                    level: .info,
                    data: [
                        "passageId": chunk.passageId ?? ""
                    ]
                )
            } else if let passageId = chunk.passageId {
                await MainActor.run {
                    observable.currentPassageId = passageId
                }
            }
        }

        private func onBufferComplete(chunk: PCMChunk) async {
            if chunk.isFinal {
                // The last buffer of this passage drained. Long-lived engine: do NOT
                // stop the engine or release the session here — they stay live for
                // the next passage (switch/auto-advance) or until stop(). Only set
                // status .stopped so the bridge's advance watcher still fires on the
                // (.stopped + currentPassageId) post-condition.
                let observable = state
                await MainActor.run { observable.update(status: .stopped) }
                let generation = playbackGeneration
                if didStartForGeneration == generation {
                    settle(.success(()), generation: generation)
                } else {
                    settle(
                        .failure(TTSEnginePlaybackError.finishedWithoutPlaying),
                        generation: generation
                    )
                }
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
            engineRunning = false
            await coordinator.releaseActiveMode(.tts)
            let message = String(describing: error)
            let observable = state
            await MainActor.run {
                observable.update(status: .error)
                observable.error = message
            }
            Log.event(
                "tts.engine.error",
                level: .error,
                data: ["error": message]
            )
            settle(
                .failure(TTSEnginePlaybackError.playbackFailed(message)),
                generation: playbackGeneration
            )
        }
    }

    // Phase 29 (29-01): TTSEngine already implements the exact start/pause/resume/
    // stop surface ReaderTTSBridge consumes, so conformance is a one-liner with no
    // behavioural change — the Phase 23/24 engine internals stay byte-identical.
    extension TTSEngine: TTSPlaying {}
#endif
