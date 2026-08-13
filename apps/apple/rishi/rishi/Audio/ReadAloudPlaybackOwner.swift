import Foundation
import ReadiumShared

@MainActor
protocol ReadAloudPlaybackOwnering: AnyObject {
    func install(controller: ReadAloudController, host: UUID) async
    func release(host: UUID) async
    func stopForAccountChange() async
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
    private var startGeneration: UInt64 = 0
    private(set) var generation: UInt64 = 0

    func makeController(
        userId: UserID,
        bookFileStorage: BookFileStorage?,
        onAllowanceFailure: (@MainActor (WorkerAllowanceError, UUID) -> Void)? = nil,
        onReadAloudPositionChange: (@MainActor (Locator) -> Void)? = nil,
        onPersistReadAloudPosition: (@MainActor (Locator) async -> Void)? = nil,
        onFirstUtteranceFinished: (@MainActor () -> Void)? = nil,
        onFirstUtteranceFailed: (@MainActor () -> Void)? = nil
    ) -> ReadAloudController {
        ReadAloudController(
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
    }

    func install(controller: ReadAloudController, host: UUID) async {
        if let activeController, activeController !== controller {
            await activeController.stop()
            activeController.dispose()
        }
        activeController = controller
        activeHost = host
        activeReader = nil
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
        let previousController = activeController
        let previousReader = activeReader
        let previousHost = activeHost
        startGeneration &+= 1
        let requestGeneration = startGeneration

        activeController = controller
        activeReader = reader
        activeHost = host
        generation &+= 1
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
            activeHost = previousHost
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
        guard activeHost == host else { return }
        await stopAndClear()
    }

    func stopForAccountChange() async {
        await stopAndClear()
        generation &+= 1
    }

    private func stopAndClear() async {
        startGeneration &+= 1
        guard let activeController else {
            activeReader = nil
            activeHost = nil
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
    }
}
