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

        private var bridgeTask: Task<Void, Never>?
        private var monitorTask: Task<Void, Never>?

        public init(streamer: TTSStreamer, state: TTSPlaybackState) {
            self.streamer = streamer
            self.state = state

            let callbacks = PlaybackCallbacks()
            self.player = AudioPlayer(
                didStartPlaying: { callbacks.didStart() },
                didFinishPlaying: { callbacks.didFinish() }
            )
            callbacks.didStart = { [weak self] in
                Task { await self?.markPlaying() }
            }
            callbacks.didFinish = { [weak self] in
                Task { await self?.markStopped() }
            }
        }

        public func start(request: TTSStreamRequest) async {
            await stop()

            await MainActor.run {
                state.error = nil
                state.currentPassageId = request.passageId
                state.update(status: .loading)
            }

            let stream = makeAudioStream(request: request)
            player.start(stream, type: kAudioFileMP3Type)
            monitorForPlaybackFailure()
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

        private func monitorForPlaybackFailure() {
            monitorTask?.cancel()
            monitorTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let snapshot = await MainActor.run {
                        (player.currentState, player.currentError)
                    }
                    if snapshot.0 == .failed {
                        await self.markFailed(message: snapshot.1?.debugDescription)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        private func markPlaying() async {
            await MainActor.run {
                state.update(status: .playing)
            }
        }

        private func markStopped() async {
            await MainActor.run {
                state.update(status: .stopped)
            }
        }

        private func markFailed(message: String?) async {
            bridgeTask?.cancel()
            bridgeTask = nil
            player.stop()
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
        }
    }

    private final class PlaybackCallbacks: @unchecked Sendable {
        var didStart: @Sendable () -> Void = {}
        var didFinish: @Sendable () -> Void = {}
    }
#endif
