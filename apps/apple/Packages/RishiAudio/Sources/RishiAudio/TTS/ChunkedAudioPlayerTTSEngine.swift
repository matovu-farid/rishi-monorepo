import Foundation
import RishiCore
import RishiLogging

#if canImport(AVFAudio) && canImport(AudioToolbox)
    import AVFAudio
    import AudioToolbox
    import ChunkedAudioPlayer

    /// Production TTS playback engine backed by `swift-chunked-audio-player`.
    ///
    /// The engine keeps our existing stream/cache transport intact, but hands the
    /// final MP3 byte stream directly to the player library so decoding and
    /// buffer scheduling are delegated to a battle-tested implementation.
    public actor ChunkedAudioPlayerTTSEngine: TTSPlaying {

        private let streamer: TTSStreamer
        private let state: TTSPlaybackState
        private let player: AudioPlayer
        private let callbacks: PlaybackCallbacks

        private var bridgeTask: Task<Void, Never>?
        private var monitorTask: Task<Void, Never>?
        /// Bumps on every `start` so async `didFinish` from a prior `stop()`
        /// cannot mark the new session `.stopped` before it has played.
        private var playbackGeneration = 0
        /// Set to `playbackGeneration` when `didStart` fires for that generation.
        private var didStartForGeneration = 0
        private var settledGeneration = 0
        private var pendingResult: Result<Void, Error>?
        private var waiter: CheckedContinuation<Void, Error>?

        public init(streamer: TTSStreamer, state: TTSPlaybackState) {
            self.streamer = streamer
            self.state = state

            let callbacks = PlaybackCallbacks()
            self.callbacks = callbacks
            self.player = AudioPlayer(
                didStartPlaying: { callbacks.didStart() },
                didFinishPlaying: { callbacks.didFinish() }
            )
        }

        public func start(request: TTSStreamRequest) async {
            await stop()
            playbackGeneration += 1
            let generation = playbackGeneration
            beginGeneration(generation)

            // Always leave `.stopped` before returning, including cache hits.
            // UI status is for controls; speak completion uses waitUntilFinished.
            let textPrefix = String(request.text.prefix(60))
                .replacingOccurrences(of: "\n", with: " ")
            await MainActor.run {
                state.error = nil
                state.currentPassageId = request.passageId
                state.update(status: .loading)
            }
            Log.event("tts.player.status", data: [
                "status": "loading",
                "generation": String(generation),
                "textPrefix": textPrefix,
                "textLen": String(request.text.count),
            ])

            callbacks.didStart = { [weak self] in
                Task { await self?.markPlaying(generation: generation, textPrefix: textPrefix) }
            }
            // AudioPlayer calls didFinishPlaying on both success (.completed)
            // AND failure (.failed). Never map a failed finish to `.stopped` —
            // CustomTTSEngine treats `.stopped` as speak success and Readium
            // advances past the failed paragraph (the observed skip).
            callbacks.didFinish = { [weak self] in
                Task {
                    await self?.handlePlaybackFinished(
                        generation: generation,
                        textPrefix: textPrefix
                    )
                }
            }

            let stream = makeAudioStream(request: request)
            player.start(stream, type: kAudioFileMP3Type)
            monitorForPlaybackFailure(generation: generation)
        }

        public func pause() async {
            player.pause()
        }

        public func resume() async {
            player.resume()
        }

        public func stop() async {
            bridgeTask?.cancel()
            bridgeTask = nil
            monitorTask?.cancel()
            monitorTask = nil
            player.stop()
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

        private func beginGeneration(_ generation: Int) {
            didStartForGeneration = 0
            pendingResult = nil
            if let existing = waiter {
                waiter = nil
                existing.resume(throwing: CancellationError())
            }
            // settledGeneration stays; settle guards on generation match.
            _ = generation
        }

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

        private func makeAudioStream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                let upstream = Task { [streamer] in
                    do {
                        for try await chunk in await streamer.stream(request) {
                            if Task.isCancelled {
                                continuation.finish()
                                return
                            }
                            continuation.yield(chunk.data)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                bridgeTask = upstream
                continuation.onTermination = { _ in upstream.cancel() }
            }
        }

        private func monitorForPlaybackFailure(generation: Int) {
            monitorTask?.cancel()
            monitorTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let snapshot = await MainActor.run {
                        (player.currentState, player.currentError)
                    }
                    if snapshot.0 == .failed {
                        await self.markFailed(
                            message: snapshot.1?.debugDescription,
                            generation: generation
                        )
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        private func handlePlaybackFinished(generation: Int, textPrefix: String) async {
            guard generation == playbackGeneration else {
                Log.event("tts.player.status.stale", data: [
                    "ignored": "finish",
                    "generation": String(generation),
                    "current": String(playbackGeneration),
                    "textPrefix": textPrefix,
                ])
                return
            }
            let snapshot = await MainActor.run {
                (player.currentState, player.currentError?.debugDescription)
            }
            if snapshot.0 == .failed {
                await markFailed(message: snapshot.1, generation: generation)
            } else {
                await markStopped(generation: generation, textPrefix: textPrefix)
            }
        }

        private func markPlaying(generation: Int, textPrefix: String) async {
            guard generation == playbackGeneration else {
                Log.event("tts.player.status.stale", data: [
                    "ignored": "playing",
                    "generation": String(generation),
                    "current": String(playbackGeneration),
                    "textPrefix": textPrefix,
                ])
                return
            }
            didStartForGeneration = generation
            await MainActor.run {
                // Do not clobber a failure that already won the race.
                guard state.status != .error else { return }
                state.update(status: .playing)
            }
            Log.event("tts.player.status", data: [
                "status": "playing",
                "generation": String(generation),
                "textPrefix": textPrefix,
            ])
        }

        private func markStopped(generation: Int, textPrefix: String) async {
            guard generation == playbackGeneration else {
                Log.event("tts.player.status.stale", data: [
                    "ignored": "stopped",
                    "generation": String(generation),
                    "current": String(playbackGeneration),
                    "textPrefix": textPrefix,
                ])
                return
            }
            await MainActor.run {
                // Do not clobber a failure that already won the race.
                guard state.status != .error else { return }
                state.update(status: .stopped)
            }
            Log.event("tts.player.status", data: [
                "status": "stopped",
                "generation": String(generation),
                "textPrefix": textPrefix,
            ])
            if didStartForGeneration == generation {
                settle(.success(()), generation: generation)
            } else {
                settle(
                    .failure(TTSEnginePlaybackError.finishedWithoutPlaying),
                    generation: generation
                )
            }
        }

        private func markFailed(message: String?, generation: Int) async {
            guard generation == playbackGeneration else { return }
            bridgeTask?.cancel()
            bridgeTask = nil
            // Avoid player.stop() here: stop() clears .failed back to .initial
            // and can race with waiters. Status/error are enough for speak().
            let text = message ?? "TTS playback failed"
            await MainActor.run {
                state.update(status: .error)
                state.error = text
            }
            Log.event(
                "tts.player.failed",
                level: .error,
                data: ["error": text]
            )
            settle(
                .failure(TTSEnginePlaybackError.playbackFailed(text)),
                generation: generation
            )
        }
    }

    private final class PlaybackCallbacks: @unchecked Sendable {
        var didStart: @Sendable () -> Void = {}
        var didFinish: @Sendable () -> Void = {}
    }
#endif
