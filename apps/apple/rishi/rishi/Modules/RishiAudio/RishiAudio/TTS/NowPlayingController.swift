import Foundation
import Observation

/// Minimal control surface NowPlayingController calls. TTSEngine implements
/// this via an extension below — keeps NowPlayingController from importing
/// the concrete actor for testability and lets plan 08-06 inject a richer
/// `SkipDelegate` if sentence-level navigation needs to land later.
public protocol TTSPlaybackControlling: Sendable {
    func pause() async
    func resume() async
    func stop() async
    func previousTrack() async
    func nextTrack() async
    func changePlaybackRate(to rate: Double) async
}

/// Observes `TTSPlaybackState` and updates `MPNowPlayingInfoCenter` plus
/// handles `MPRemoteCommandCenter` input. Lives on the main actor because
/// both MediaPlayer-side surfaces are MainActor-adjacent.
///
/// Lifecycle:
///   - `attach(state:controller:metadata:)` once per session — sets
///     metadata, installs handlers, starts observing status.
///   - `detach()` — cancels observation, unregisters handlers, clears
///     the info surface.
@MainActor
public final class NowPlayingController {

    private let infoSurface: any NowPlayingInfoSurface
    private let commandSurface: any RemoteCommandSurface
    private weak var state: TTSPlaybackState?
    private var controller: (any TTSPlaybackControlling)?
    private var observationTask: Task<Void, Never>?
    private var lastStatus: TTSStatus?
    private var playbackRate = 1.0
    private var supportedPlaybackRates = TTSSettings.speedPresets

    public init(
        infoSurface: any NowPlayingInfoSurface,
        commandSurface: any RemoteCommandSurface
    ) {
        self.infoSurface = infoSurface
        self.commandSurface = commandSurface
    }

    public func attach(
        state: TTSPlaybackState,
        controller: any TTSPlaybackControlling,
        metadata: NowPlayingMetadata
    ) {
        guard self.state == nil, self.controller == nil, observationTask == nil else { return }
        self.state = state
        self.controller = controller
        lastStatus = nil
        playbackRate = metadata.playbackRate
        supportedPlaybackRates = metadata.supportedPlaybackRates
        infoSurface.setMetadata(metadata)
        installRemoteHandlers(for: controller)
        startObserving(state: state)
    }

    public func detach() {
        guard state != nil || controller != nil || observationTask != nil else { return }
        observationTask?.cancel()
        observationTask = nil
        commandSurface.unregister()
        infoSurface.clear()
        state = nil
        controller = nil
    }

    private func installRemoteHandlers(for controller: any TTSPlaybackControlling) {
        // Strong capture is intentional: `TTSPlaybackControlling` is not
        // class-bound (TTSEngine is an `actor`, which cannot be `weak`),
        // and the controller's lifetime is bounded by the session —
        // `detach()` drops the strong reference on this side, and the
        // closures are released when `commandSurface.unregister()` runs.
        let handlers = RemoteCommandHandlers(
            // KEEP: MPRemoteCommandCenter handler hops into the TTSPlaybackControlling
            // actor (TTSEngine is an actor). Outer Task chains the await; no main work.
            onPlay: {
                Task { await controller.resume() }
            },
            // KEEP: same pattern as onPlay — actor hop only.
            onPause: {
                Task { await controller.pause() }
            },
            onTogglePlayPause: { [weak self] in
                let isPlaying = self?.state?.status == .playing
                // KEEP: actor hop only (controller is the TTSEngine actor).
                Task {
                    if isPlaying {
                        await controller.pause()
                    } else {
                        await controller.resume()
                    }
                }
            },
            onPreviousTrack: {
                Task { await controller.previousTrack() }
            },
            onNextTrack: {
                Task { await controller.nextTrack() }
            },
            onStop: {
                Task { await controller.stop() }
            },
            onChangePlaybackRate: { [weak self] rate in
                guard let self,
                      self.supportedPlaybackRates.contains(where: { abs($0 - rate) < 0.0001 })
                else { return .commandFailed }
                self.playbackRate = rate
                self.infoSurface.setPlaybackRate(self.lastStatus == .playing ? rate : 0.0)
                Task { await controller.changePlaybackRate(to: rate) }
                return .success
            }
        )
        commandSurface.register(handlers: handlers)
    }

    /// Lightweight 50ms poll of the @MainActor @Observable state. Cheaper
    /// than re-arming `withObservationTracking` from an async loop and
    /// well under the engine's own status-change cadence; only fires
    /// `infoSurface` calls on actual transitions so the Fake's call log
    /// stays minimal.
    private func startObserving(state: TTSPlaybackState) {
        observationTask?.cancel()
        // KEEP: 50ms poll on @MainActor; reads MainActor @Observable state and
        // updates MPNowPlayingInfoCenter (MainActor-adjacent). Observation
        // push refactor deferred to v1.1 ADR backlog (RESEARCH §F-P1-03 /
        // plan 19-12). MainActor is required here because the read targets
        // MainActor state and the writes target MediaPlayer surfaces.
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = state.status
                self.apply(status: status)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func apply(status: TTSStatus) {
        if status != lastStatus {
            lastStatus = status
            switch status {
            case .playing:
                infoSurface.setPlaybackRate(playbackRate)
            case .paused:
                infoSurface.setPlaybackRate(0.0)
            // A TTS status describes the current paragraph, not the reader
            // session. In particular, the engine emits `.stopped` between
            // paragraphs. The lifecycle owner explicitly calls `detach()`
            // when the read-aloud session actually ends.
            case .stopped, .idle, .error:
                break
            case .loading:
                break
            }
        }
    }
}
