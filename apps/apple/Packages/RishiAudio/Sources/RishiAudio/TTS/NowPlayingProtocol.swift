import Foundation
import RishiLogging

// MARK: - Protocols

/// Abstract surface for `MPNowPlayingInfoCenter` — the controller writes
/// metadata + playback rate + elapsed time through this seam so tests can
/// swap in a `FakeNowPlayingInfoSurface` and assert call order without
/// touching MediaPlayer.
public protocol NowPlayingInfoSurface: Sendable {
    @MainActor func setMetadata(_ metadata: NowPlayingMetadata)
    @MainActor func setPlaybackRate(_ rate: Double)
    @MainActor func setElapsed(_ elapsed: TimeInterval)
    @MainActor func clear()
}

/// Abstract surface for `MPRemoteCommandCenter` — the controller registers
/// `RemoteCommandHandlers` (play/pause/skip/scrub closures) on attach and
/// unregisters on detach. Production impl wires the closures to
/// `addTarget(_:handler:)` on each command; the Fake records the call
/// order and exposes a `simulate(_:)` test seam.
public protocol RemoteCommandSurface: Sendable {
    @MainActor func register(handlers: RemoteCommandHandlers)
    @MainActor func unregister()
}

// MARK: - Production impls

#if canImport(MediaPlayer) && (os(iOS) || targetEnvironment(macCatalyst))
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Wraps `MPNowPlayingInfoCenter.default()`. `@MainActor` because the
/// underlying API is UIKit-style and re-entrant updates to
/// `nowPlayingInfo` must serialise on the main run-loop.
@MainActor
public final class MPNowPlayingInfoCenterAdapter: NowPlayingInfoSurface {

    public init() {}

    public func setMetadata(_ metadata: NowPlayingMetadata) {
        applyMetadata(metadata)
    }

    public func setPlaybackRate(_ rate: Double) {
        applyRate(rate)
    }

    public func setElapsed(_ elapsed: TimeInterval) {
        applyElapsed(elapsed)
    }

    public func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func applyMetadata(_ metadata: NowPlayingMetadata) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = metadata.title
        if let author = metadata.author {
            info[MPMediaItemPropertyArtist] = author
        }
        if let duration = metadata.durationEstimate {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        #if canImport(UIKit)
        if let data = metadata.coverData, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func applyRate(_ rate: Double) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func applyElapsed(_ elapsed: TimeInterval) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

/// Wraps `MPRemoteCommandCenter.shared()`. `addTarget(_:handler:)` on each
/// command; `removeTarget(nil)` on unregister.
@MainActor
public final class MPRemoteCommandCenterAdapter: RemoteCommandSurface {

    public init() {}

    public func register(handlers: RemoteCommandHandlers) {
        applyHandlers(handlers)
    }

    public func unregister() {
        removeAll()
    }

    private func applyHandlers(_ handlers: RemoteCommandHandlers) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { _ in
            MainActor.assumeIsolated { handlers.onPlay() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { handlers.onPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { handlers.onTogglePlayPause() }
            return .success
        }
        center.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            MainActor.assumeIsolated { handlers.onSkipForward(interval) }
            return .success
        }
        center.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            MainActor.assumeIsolated { handlers.onSkipBackward(interval) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let pos = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            MainActor.assumeIsolated { handlers.onScrub(pos) }
            return .success
        }
    }

    private func removeAll() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }
}
#endif

// MARK: - Fakes (test helpers, ship in main target so downstream test
// targets can inject without re-declaring the protocol surface)

public final class FakeNowPlayingInfoSurface: NowPlayingInfoSurface, @unchecked Sendable {
    public enum Call: Sendable, Equatable {
        case metadata(NowPlayingMetadata)
        case rate(Double)
        case elapsed(TimeInterval)
        case clear
    }

    private let lock = NSLock()
    private var _calls: [Call] = []

    public init() {}

    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public func setMetadata(_ metadata: NowPlayingMetadata) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.metadata(metadata))
    }
    public func setPlaybackRate(_ rate: Double) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.rate(rate))
    }
    public func setElapsed(_ elapsed: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.elapsed(elapsed))
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.clear)
    }
}

public final class FakeRemoteCommandSurface: RemoteCommandSurface, @unchecked Sendable {
    public enum Call: Sendable, Equatable {
        case register
        case unregister
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _handlers: RemoteCommandHandlers?

    public init() {}

    public var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public func register(handlers: RemoteCommandHandlers) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.register)
        _handlers = handlers
    }
    public func unregister() {
        lock.lock(); defer { lock.unlock() }
        _calls.append(.unregister)
        _handlers = nil
    }

    /// Test seam — invoke the registered handler for a given command.
    @MainActor
    public func simulate(_ command: RemoteCommand) {
        let handlers: RemoteCommandHandlers? = {
            lock.lock(); defer { lock.unlock() }
            return _handlers
        }()
        guard let handlers else { return }
        switch command {
        case .play: handlers.onPlay()
        case .pause: handlers.onPause()
        case .togglePlayPause: handlers.onTogglePlayPause()
        case .skipForward(let s): handlers.onSkipForward(s)
        case .skipBackward(let s): handlers.onSkipBackward(s)
        case .scrub(let s): handlers.onScrub(s)
        }
    }
}
