import Foundation



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
        private var player: AudioPlayer?

        private var bridgeTask: Task<Void, Never>?
        private var monitorTask: Task<Void, Never>?
        /// Bumps on every `start` so async `didFinish` from a prior `stop()`
        /// cannot mark the new session `.stopped` before it has played.
        private var playbackGeneration = 0
        private var activeRequestTokens: TTSPlaybackTokenSnapshot?
        /// Set to `playbackGeneration` when `didStart` fires for that generation.
        private var didStartForGeneration = 0
        private var settledGeneration = 0
        private var playbackStartedAt: Date?
        private var pendingResult: Result<Void, Error>?
        private var waiter: CheckedContinuation<Void, Error>?

        public init(streamer: TTSStreamer, state: TTSPlaybackState) {
            self.streamer = streamer
            self.state = state
            self.player = nil
        }

        public func start(request: TTSStreamRequest) async {
            playbackGeneration += 1
            activeRequestTokens = request.tokenSnapshot
            let generation = playbackGeneration
            await stopCurrent(invalidate: false)
            // A concurrent stop/start may have superseded this request while
            // teardown was suspended. Never create a player for that stale
            // generation.
            guard generation == playbackGeneration else { return }
            beginGeneration(generation)

            // Always leave `.stopped` before returning, including cache hits.
            // UI status is for controls; speak completion uses waitUntilFinished.
            let correlationID = request.requestToken.uuidString
            await MainActor.run {
                state.activate(tokens: request.tokenSnapshot)
                if state.typedFailure == nil { state.clearFailure() }
                state.currentPassageId = request.passageId
                state.update(status: .loading)
            }
            Log.event("tts.player.status", data: [
                "feature": "tts",
                "operation": "tts.player",
                "stage": "loading",
                "correlation_id": correlationID,
                "status": "loading",
                "generation": String(generation),
                "request_chars": String(request.text.count),
            ])

            let callbacks = PlaybackCallbacks()
            callbacks.didStart = { [weak self] in
                Task { await self?.markPlaying(generation: generation, correlationID: correlationID) }
            }
            // AudioPlayer calls didFinishPlaying on both success (.completed)
            // AND failure (.failed). Never map a failed finish to `.stopped` —
            // CustomTTSEngine treats `.stopped` as speak success and Readium
            // advances past the failed paragraph (the observed skip).
            callbacks.didFinish = { [weak self] in
                Task {
                    await self?.handlePlaybackFinished(
                        generation: generation,
                        correlationID: correlationID
                    )
                }
            }

            let player = AudioPlayer(
                didStartPlaying: { callbacks.didStart() },
                didFinishPlaying: { callbacks.didFinish() }
            )
            self.player = player
            let stream = makeAudioStream(request: request, generation: generation)
            player.start(stream, type: kAudioFileMP3Type)
            monitorForPlaybackFailure(player: player, generation: generation, correlationID: correlationID)
        }

        public func pause() async {
            player?.pause()
            Log.event("tts.player.paused", level: .info, data: playbackTelemetry(stage: "pause"))
        }

        public func resume() async {
            player?.resume()
            Log.event("tts.player.resumed", level: .info, data: playbackTelemetry(stage: "resume"))
        }

        public func stop() async {
            Log.event("tts.player.cancelled", level: .warning, data: playbackTelemetry(
                stage: "stop",
                extra: ["cancel_reason": "user_stop"]
            ))
            await stopCurrent(invalidate: true)
        }

        public func stop(ifCurrent tokens: TTSPlaybackTokenSnapshot) async {
            guard activeRequestTokens == tokens else { return }
            Log.event("tts.player.cancelled", level: .warning, data: playbackTelemetry(
                stage: "stop",
                extra: ["cancel_reason": "tokened_stop"]
            ))
            await stopCurrent(invalidate: true)
        }

        private func stopCurrent(invalidate: Bool) async {
            let stoppedGeneration = playbackGeneration
            if invalidate {
                // Resume waiters before fencing the generation; settle() only
                // accepts the generation that owns the waiter.
                settle(.failure(CancellationError()), generation: stoppedGeneration)
                playbackGeneration += 1
                activeRequestTokens = nil
            }
            let bridge = bridgeTask
            bridgeTask?.cancel()
            bridgeTask = nil
            monitorTask?.cancel()
            monitorTask = nil
            let playerToStop = player
            player = nil
            // Stop the native player before awaiting the stream bridge. The
            // player owns the stream consumer; waiting first can strand a
            // cancellation indefinitely when the upstream is quiet.
            playerToStop?.stop()
            await bridge?.value
            // The cancellation result was delivered before invalidation above.
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
            playbackStartedAt = nil
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

        private func makeAudioStream(
            request: TTSStreamRequest,
            generation: Int
        ) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                let upstream = Task { [weak self, streamer] in
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
                if let allowance = error as? WorkerAllowanceError,
                   let self,
                   await self.isCurrent(generation: generation, tokens: request.tokenSnapshot) {
                    await MainActor.run {
                        state.recordTypedFailure(allowance, tokens: request.tokenSnapshot)
                    }
                }
                continuation.finish(throwing: error)
                    }
                }
                bridgeTask = upstream
                continuation.onTermination = { _ in upstream.cancel() }
            }
        }

        private func isCurrent(
            generation: Int,
            tokens: TTSPlaybackTokenSnapshot
        ) -> Bool {
            playbackGeneration == generation && activeRequestTokens == tokens
        }

        private func monitorForPlaybackFailure(
            player: AudioPlayer,
            generation: Int,
            correlationID: String
        ) {
            monitorTask?.cancel()
            monitorTask = Task { [weak self, player] in
                guard let self else { return }
                while !Task.isCancelled {
                    let snapshot = await MainActor.run {
                        (player.currentState, player.currentError)
                    }
                    if snapshot.0 == .failed {
                        await self.markFailed(
                            message: snapshot.1?.debugDescription,
                            generation: generation,
                            correlationID: correlationID
                        )
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        private func handlePlaybackFinished(generation: Int, correlationID: String) async {
            guard generation == playbackGeneration else {
                Log.event("tts.player.status.stale", data: [
                    "ignored": "finish",
                    "generation": String(generation),
                    "current": String(playbackGeneration),
                    "correlation_id": correlationID,
                ])
                return
            }
            guard let player else { return }
            let snapshot = await MainActor.run {
                (player.currentState, player.currentError?.debugDescription)
            }
            if snapshot.0 == .failed {
                await markFailed(message: snapshot.1, generation: generation, correlationID: correlationID)
            } else {
                await markStopped(generation: generation, correlationID: correlationID)
            }
        }

        private func markPlaying(generation: Int, correlationID: String) async {
            guard generation == playbackGeneration else {
                Log.event("tts.player.status.stale", data: [
                    "ignored": "playing",
                    "generation": String(generation),
                    "current": String(playbackGeneration),
                    "correlation_id": correlationID,
                ])
                return
            }
            guard let tokens = activeRequestTokens else { return }
            await MainActor.run {
                // Do not clobber a failure that already won the race.
                guard state.activeTokenSnapshot == tokens else { return }
                guard state.status != .error else { return }
                state.update(status: .playing)
            }
            guard generation == playbackGeneration else { return }
            didStartForGeneration = generation
            playbackStartedAt = Date()
            Log.event("tts.player.status", data: [
                "feature": "tts",
                "operation": "tts.player",
                "stage": "playback",
                "correlation_id": correlationID,
                "status": "playing",
                "generation": String(generation),
            ])
        }

        private func markStopped(generation: Int, correlationID: String) async {
            guard generation == playbackGeneration else {
                Log.event("tts.player.status.stale", data: [
                    "ignored": "stopped",
                    "generation": String(generation),
                    "current": String(playbackGeneration),
                    "correlation_id": correlationID,
                ])
                return
            }
            guard let tokens = activeRequestTokens else { return }
            await MainActor.run {
                // Do not clobber a typed or generic failure that already won.
                guard state.activeTokenSnapshot == tokens else { return }
                guard state.status != .error else { return }
                state.update(status: .stopped)
            }
            guard generation == playbackGeneration else { return }
            Log.event("tts.player.status", data: [
                "feature": "tts",
                "operation": "tts.player",
                "stage": "playback",
                "correlation_id": correlationID,
                "status": "stopped",
                "generation": String(generation),
                "duration_ms": playbackStartedAt.map {
                    String(Int(Date().timeIntervalSince($0) * 1000))
                } ?? "0",
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

        private func markFailed(
            message: String?,
            generation: Int,
            correlationID: String
        ) async {
            guard generation == playbackGeneration else { return }
            guard let tokens = activeRequestTokens else { return }
            bridgeTask?.cancel()
            bridgeTask = nil
            // Avoid player.stop() here: stop() clears .failed back to .initial
            // and can race with waiters. Status/error are enough for speak().
            let text = message ?? "TTS playback failed"
            await MainActor.run {
                guard state.typedFailure == nil else { return }
                guard state.activeTokenSnapshot == tokens else { return }
                state.recordUserFacingFailure(.audioPlayback)
            }
            guard generation == playbackGeneration else { return }
            Log.error(
                "tts.player.failed",
                error: NSError(domain: "org.fidexa.rishi.tts", code: 4),
                diagnostic: TelemetryDiagnostic(
                    feature: "tts",
                    operation: "tts.player",
                    stage: "playback",
                    errorCode: "audio_playback_failed",
                    fields: [
                        "correlation_id": correlationID,
                        "duration_ms": playbackStartedAt.map {
                            String(Int(Date().timeIntervalSince($0) * 1000))
                        } ?? "0",
                    ]
                )
            )
            settle(
                .failure(TTSEnginePlaybackError.playbackFailed(text)),
                generation: generation
            )
        }

        private func playbackTelemetry(
            stage: String,
            extra: [String: String] = [:]
        ) -> [String: String] {
            var data = [
                "feature": "tts",
                "operation": "tts.player",
                "stage": stage,
            ]
            if let tokens = activeRequestTokens {
                data["correlation_id"] = tokens.requestToken.uuidString
            }
            if let playbackStartedAt {
                data["duration_ms"] = String(
                    Int(Date().timeIntervalSince(playbackStartedAt) * 1000)
                )
            }
            data.merge(extra) { _, new in new }
            return data
        }
    }

    private final class PlaybackCallbacks: @unchecked Sendable {
        var didStart: @Sendable () -> Void = {}
        var didFinish: @Sendable () -> Void = {}
    }
#endif
