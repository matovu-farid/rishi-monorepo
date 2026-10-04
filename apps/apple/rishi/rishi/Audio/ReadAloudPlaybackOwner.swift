import Foundation
import ReadiumShared
import RishiWatchShared

enum RemotePlaybackCommandError: Error, Sendable {
    case staleGeneration
    case noActivePlayback
    case invalidCommand
    case revoked
}

private enum RemotePlaybackCommandResult: Sendable {
    case success
    case failure(RemotePlaybackCommandError)
}

@MainActor
protocol ReadAloudPlaybackOwnering: AnyObject {
    func install(controller: ReadAloudController, host: UUID) async
    func release(host: UUID) async
    func stop(host: UUID) async
    func stop(reader: ReaderViewModel) async -> Bool
    func stopForAccountChange() async
    func setVolume(_ volume: Float) async
}

/// Owns the single active read-aloud controller shared by phone and CarPlay.
/// Hosts may release only their own binding; disconnecting a CarPlay scene never
/// tears down playback started by another host.
@MainActor
final class ReadAloudPlaybackOwner: ReadAloudPlaybackOwnering {
    private let ttsEngine: any TTSPlaying
    private let ttsState: TTSPlaybackState
    private let ttsSettingsStore: any TTSSettingsStore
    private let ttsPrewarmer: TTSPrewarmer
    private let ttsPresence: TTSPresenceController
    private let coordinator: AudioSessionCoordinator
    private let nowPlayingController: NowPlayingController

    init(
        ttsEngine: any TTSPlaying,
        ttsState: TTSPlaybackState,
        ttsSettingsStore: any TTSSettingsStore,
        ttsPrewarmer: TTSPrewarmer,
        ttsPresence: TTSPresenceController,
        coordinator: AudioSessionCoordinator,
        nowPlayingController: NowPlayingController
    ) {
        self.ttsEngine = ttsEngine
        self.ttsState = ttsState
        self.ttsSettingsStore = ttsSettingsStore
        self.ttsPrewarmer = ttsPrewarmer
        self.ttsPresence = ttsPresence
        self.coordinator = coordinator
        self.nowPlayingController = nowPlayingController
    }

    private(set) var activeController: ReadAloudController?
    private(set) var activeHost: UUID?
    private var activeReader: ReaderViewModel?
    private var sourceInvalidationTask: Task<Void, Never>?
    private(set) var watchBookTitle: String?
    private var startGeneration: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private let lifecycleQueue = PlaybackLifecycleQueue()
    private var remotePlaybackSession: RemotePlaybackSessionCapability?
    private var sharedFollowerHost: UUID?
    /// Unlike activeHost, this survives a scene release while its audio is
    /// still running, so another reader cannot inherit the follower gate.
    private var playbackHost: UUID?

    /// System media and watch commands must not turn a follower into a local
    /// controller. The host fence keeps another reader window unaffected.
    func setSharedSessionFollower(_ isFollowing: Bool, host: UUID) {
        if isFollowing {
            sharedFollowerHost = host
        } else if sharedFollowerHost == host {
            sharedFollowerHost = nil
        }
        synchronizeRemoteCommandPolicy()
    }

    private var remoteCommandsBlocked: Bool {
        sharedFollowerHost != nil && playbackHost == sharedFollowerHost
    }

    private func synchronizeRemoteCommandPolicy() {
        nowPlayingController.setRemoteCommandsEnabled(!remoteCommandsBlocked)
    }

    var hasActivePlaybackSession: Bool {
        guard let controller = activeController else { return false }
        return controller.hasActivePlaybackSession
    }

    func makeController(
        userId: UserID,
        bookFileStorage: BookFileStorage?,
        onAllowanceFailure: (@MainActor (WorkerAllowanceError, UUID) -> Void)? = nil,
        onReadAloudPositionChange: (@MainActor (Locator) -> Void)? = nil,
        onPersistReadAloudPosition: (@MainActor (Locator) async -> Void)? = nil,
        onFirstUtteranceFinished: (@MainActor () -> Void)? = nil,
        onFirstUtteranceFailed: (@MainActor () -> Void)? = nil
    ) -> ReadAloudController {
        let controller = ReadAloudController(
            ttsEngine: ttsEngine,
            ttsState: ttsState,
            ttsSettingsStore: ttsSettingsStore,
            ttsPrewarmer: ttsPrewarmer,
            ttsPresence: ttsPresence,
            coordidator: coordinator,
            userId: userId,
            nowPlayingController: nowPlayingController,
            bookFileStorage: bookFileStorage,
            onAllowanceFailure: onAllowanceFailure,
            onReadAloudPositionChange: onReadAloudPositionChange,
            onPersistReadAloudPosition: onPersistReadAloudPosition,
            onFirstUtteranceFinished: onFirstUtteranceFinished,
            onFirstUtteranceFailed: onFirstUtteranceFailed
        )
        controller.onPlaybackSessionInvalidated = { [weak self, weak controller] in
            guard let self, let controller, self.activeController === controller else { return }
            self.remotePlaybackSession?.revoke()
            self.remotePlaybackSession = nil
        }
        return controller
    }

    func install(controller: ReadAloudController, host: UUID) async {
        remotePlaybackSession?.revoke()
        await lifecycleQueue.enqueue { [weak self] in
            guard let self else { return }
            await self.installInternal(controller: controller, host: host)
        }
    }

    private func installInternal(controller: ReadAloudController, host: UUID) async {
        if let activeController, activeController !== controller {
            await activeController.stop()
            activeController.dispose()
        }
        activeController = controller
        activeHost = host
        playbackHost = host
        synchronizeRemoteCommandPolicy()
        activeReader = nil
        sourceInvalidationTask?.cancel()
        sourceInvalidationTask = nil
        watchBookTitle = nil
        generation &+= 1
    }

    /// Starts a replacement without disposing the previous controller until
    /// the candidate has reached a usable state. If the candidate reports a
    /// playback error, the previous reader is restarted and remains active.
    func start(
        controller: ReadAloudController,
        reader: ReaderViewModel,
        host: UUID,
        from startLocator: Locator? = nil
    ) async -> Bool {
        let result = await startWithGeneration(
            controller: controller,
            reader: reader,
            host: host,
            from: startLocator
        )
        return result.started
    }

    /// Returns the generation installed by this exact start. Shared-reading
    /// cleanup uses it to avoid stopping a newer request on the same host.
    func startWithGeneration(
        controller: ReadAloudController,
        reader: ReaderViewModel,
        host: UUID,
        from startLocator: Locator? = nil
    ) async -> (started: Bool, generation: UInt64?) {
        remotePlaybackSession?.revoke()
        return await lifecycleQueue.enqueue { [weak self] in
            guard let self else { return (false, nil) }
            let started = await self.startInternal(
                controller: controller,
                reader: reader,
                host: host,
                from: startLocator
            )
            return (started, started ? self.generation : nil)
        }
    }

    private func startInternal(
        controller: ReadAloudController,
        reader: ReaderViewModel,
        host: UUID,
        from startLocator: Locator? = nil
    ) async -> Bool {
        let previousController = activeController
        let previousReader = activeReader
        let previousHost = activeHost
        let previousPlaybackHost = playbackHost
        let previousBookTitle = watchBookTitle
        startGeneration &+= 1
        let requestGeneration = startGeneration

        activeController = controller
        activeReader = reader
        observeSourceInvalidation(for: reader)
        activeHost = host
        playbackHost = host
        synchronizeRemoteCommandPolicy()
        watchBookTitle = reader.book.title
        generation &+= 1
        remotePlaybackSession = RemotePlaybackSessionCapability(
            processSessionID: UUID(),
            accountGeneration: 0,
            playbackGeneration: generation
        )
        if let startLocator {
            await controller.startReader(vm: reader, from: startLocator)
        } else {
            await controller.startReader(vm: reader)
        }

        guard requestGeneration == startGeneration,
              activeController === controller else {
            await controller.stop()
            controller.dispose()
            return false
        }

        guard ttsState.status != .error else {
            await controller.stop()
            controller.dispose()
            guard requestGeneration == startGeneration,
                  activeController === controller else { return false }
            activeController = previousController
            activeReader = previousReader
            observeSourceInvalidation(for: previousReader)
            activeHost = previousHost
            playbackHost = previousPlaybackHost
            synchronizeRemoteCommandPolicy()
            watchBookTitle = previousBookTitle
            remotePlaybackSession = previousController.map {
                _ in RemotePlaybackSessionCapability(
                    processSessionID: UUID(),
                    accountGeneration: 0,
                    playbackGeneration: generation
                )
            }
            if let previousController, let previousReader {
                await previousController.startReader(vm: previousReader)
            }
            return false
        }

        if let previousController, previousController !== controller {
            await previousController.stop()
            previousController.dispose()
        }
        return true
    }

    func release(host: UUID) async {
        await lifecycleQueue.enqueue { [weak self] in
            guard let self, self.activeHost == host else { return }
            // Releasing a host only detaches that scene. The shared audio
            // session may still be intentionally playing while the phone is
            // locked or while CarPlay reconnects.
            self.activeHost = nil
            self.synchronizeRemoteCommandPolicy()
        }
    }

    func stop(host: UUID) async {
        await lifecycleQueue.enqueue { [weak self] in
            guard let self, self.activeHost == host else { return }
            await self.stopAndClear()
            self.generation &+= 1
        }
    }

    /// Stops only the playback session that still retains this reader. The
    /// active reader identity remains authoritative after its scene host has
    /// detached, so source revocation can drain old audio without affecting a
    /// newer reader or playback session.
    func stop(reader: ReaderViewModel) async -> Bool {
        await lifecycleQueue.enqueue { [weak self] in
            guard let self, self.activeReader === reader else { return false }
            await self.stopAndClear()
            self.generation &+= 1
            return true
        }
    }

    /// Atomically checks ownership inside the lifecycle queue. A stale shared
    /// reader start must not stop playback installed by a newer generation.
    func stop(host: UUID, ifGeneration expectedGeneration: UInt64) async {
        await lifecycleQueue.enqueue { [weak self] in
            guard let self,
                  self.activeHost == host,
                  self.generation == expectedGeneration else { return }
            await self.stopAndClear()
            self.generation &+= 1
        }
    }

    func setVolume(_ volume: Float) async {
        await ttsEngine.setVolume(max(0, min(volume, 1)))
    }

    func stopForAccountChange() async {
        remotePlaybackSession?.revoke()
        await lifecycleQueue.enqueue { [weak self] in
            guard let self else { return }
            await self.stopAndClear()
            self.generation &+= 1
        }
    }

    func executeRemoteWatchCommand(
        _ command: WatchPlaybackCommand,
        expectedGeneration: UInt64,
        lease: RemoteCommandLease? = nil
    ) async throws {
        let result: RemotePlaybackCommandResult = await lifecycleQueue.enqueue { [weak self] in
            defer { lease?.finish() }
            guard let self else { return .failure(.revoked) }
            guard self.generation == expectedGeneration else { return .failure(.staleGeneration) }
            guard !self.remoteCommandsBlocked else { return .failure(.revoked) }
            guard let controller = self.activeController else { return .failure(.noActivePlayback) }
            guard self.remotePlaybackSession?.isValid == true,
                  lease?.isValid ?? true,
                  lease.map({ $0.playbackGeneration == expectedGeneration }) ?? true
            else { return .failure(.revoked) }
            var didStop = false
            switch command {
            case .togglePlayback: await controller.togglePlayback(lease: lease)
            case .previousUnit: await controller.previous(lease: lease)
            case .nextUnit: await controller.next(lease: lease)
            case .stop:
                await controller.stop(lease: lease)
                remotePlaybackSession?.revoke()
                remotePlaybackSession = nil
                didStop = true
            case let .setPlaybackRate(rate):
                guard rate.isFinite, (0.25...4).contains(rate) else { return .failure(.invalidCommand) }
                await controller.applyPlaybackRate(rate, lease: lease)
            case .unknown: return .failure(.invalidCommand)
            }
            guard didStop || self.remotePlaybackSession?.isValid == true,
                  lease?.isValid ?? true else { return .failure(.revoked) }
            return .success
        }
        if case let .failure(error) = result { throw error }
    }

    private func stopAndClear() async {
        startGeneration &+= 1
        sourceInvalidationTask?.cancel()
        sourceInvalidationTask = nil
        remotePlaybackSession?.revoke()
        remotePlaybackSession = nil
        guard let activeController else {
            activeReader = nil
            activeHost = nil
            playbackHost = nil
            synchronizeRemoteCommandPolicy()
            watchBookTitle = nil
            return
        }
        let teardownGeneration = startGeneration
        let controller = activeController
        await controller.stop()
        guard teardownGeneration == startGeneration,
              self.activeController === controller else { return }
        controller.dispose()
        self.activeController = nil
        activeReader = nil
        activeHost = nil
        playbackHost = nil
        synchronizeRemoteCommandPolicy()
        watchBookTitle = nil
    }

    private func observeSourceInvalidation(for reader: ReaderViewModel?) {
        sourceInvalidationTask?.cancel()
        sourceInvalidationTask = nil
        guard let reader, let invalidation = reader.sourceInvalidation else { return }
        sourceInvalidationTask = Task { @MainActor [weak self, weak reader] in
            for await _ in invalidation {
                guard !Task.isCancelled, let self, let reader else { return }
                _ = await self.stop(reader: reader)
                return
            }
        }
    }
}
