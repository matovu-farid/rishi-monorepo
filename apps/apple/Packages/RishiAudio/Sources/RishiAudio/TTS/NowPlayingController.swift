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
    func skip(seconds: TimeInterval) async
    func scrub(toSeconds seconds: TimeInterval) async
}

#if canImport(AVFAudio)
extension TTSEngine: TTSPlaybackControlling {
    /// Phase 8 v1: sentence-level navigation lives in the reader VM
    /// extension (plan 08-06). Lock-screen surfaces the command but the
    /// engine no-ops it for now.
    public func skip(seconds: TimeInterval) async {
        _ = seconds
    }
    public func scrub(toSeconds seconds: TimeInterval) async {
        _ = seconds
    }
}
#endif

/// Observes `TTSPlaybackState` and updates `MPNowPlayingInfoCenter` plus
/// handles `MPRemoteCommandCenter` input. Lives on the main actor because
/// both MediaPlayer-side surfaces are MainActor-adjacent.
///
/// Lifecycle:
///   - `attach(state:controller:metadata:)` once per session — sets
///     metadata, installs handlers, starts observing status/elapsed.
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
    private var lastElapsed: TimeInterval?

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
        self.state = state
        self.controller = controller
        lastStatus = nil
        lastElapsed = nil
        infoSurface.setMetadata(metadata)
        installRemoteHandlers(for: controller)
        startObserving(state: state)
    }

    public func detach() {
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
            onPlay: {
                Task { await controller.resume() }
            },
            onPause: {
                Task { await controller.pause() }
            },
            onTogglePlayPause: { [weak self] in
                let isPlaying = self?.state?.status == .playing
                Task {
                    if isPlaying {
                        await controller.pause()
                    } else {
                        await controller.resume()
                    }
                }
            },
            onSkipForward: { seconds in
                Task { await controller.skip(seconds: seconds) }
            },
            onSkipBackward: { seconds in
                Task { await controller.skip(seconds: -seconds) }
            },
            onScrub: { seconds in
                Task { await controller.scrub(toSeconds: seconds) }
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
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let status = state.status
                let elapsed = state.elapsed
                self.apply(status: status, elapsed: elapsed)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func apply(status: TTSStatus, elapsed: TimeInterval) {
        if status != lastStatus {
            lastStatus = status
            switch status {
            case .playing:
                infoSurface.setPlaybackRate(1.0)
                infoSurface.setElapsed(elapsed)
                lastElapsed = elapsed
            case .paused:
                infoSurface.setPlaybackRate(0.0)
                infoSurface.setElapsed(elapsed)
                lastElapsed = elapsed
            case .stopped, .idle, .error:
                infoSurface.clear()
                lastElapsed = nil
            case .loading:
                break
            }
        } else if status == .playing, elapsed != lastElapsed {
            infoSurface.setElapsed(elapsed)
            lastElapsed = elapsed
        }
    }
}
