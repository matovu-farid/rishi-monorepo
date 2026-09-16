import Foundation
import Observation



@MainActor
final class ReaderTTSBridge {

    private let engine: any TTSPlaying
    private let state: TTSPlaybackState
    private let tracker: TTSPassageTracker
    private let settingsStore: any TTSSettingsStore
    private let userId: UserID
    private let onPassageChange: (Int?) -> Void

    private let advanceWatcher: ParagraphAdvanceWatcher

    private let readAhead: ReadAheadCoordinator

    private let onParagraphsExhausted: () async -> [String]

    private let onParagraphsBeforeStart: () async -> [String]
    private let sessionToken: UUID

    private var paragraphs: [String] = []
    private var currentIndex = 0
    private var consumeTask: Task<Void, Never>?
    private var coordinator: AudioSessionCoordinator

    init(
        engine: any TTSPlaying,
        state: TTSPlaybackState,
        tracker: TTSPassageTracker,
        prewarmer: TTSPrewarmer,
        settingsStore: any TTSSettingsStore,
        userId: UserID,
        coordinator: AudioSessionCoordinator,
        onPassageChange: @escaping (Int?) -> Void,
        onParagraphsExhausted: @escaping () async -> [String] = { [] },
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] },
        sessionToken: UUID = UUID()
    ) {
        self.engine = engine
        self.state = state
        self.tracker = tracker
        self.settingsStore = settingsStore
        self.userId = userId
        self.onPassageChange = onPassageChange
        self.onParagraphsExhausted = onParagraphsExhausted
        self.onParagraphsBeforeStart = onParagraphsBeforeStart
        self.sessionToken = sessionToken

        self.advanceWatcher = ParagraphAdvanceWatcher(state: state)
        self.readAhead = ReadAheadCoordinator(prewarmer: prewarmer)
        self.coordinator = coordinator
    }
    
   

    @discardableResult
    func start(paragraphs: [String], startIndex: Int = 0) async -> Bool {
        await stop()
        guard !paragraphs.isEmpty else { return false }
        self.paragraphs = paragraphs
        self.currentIndex = min(max(startIndex, 0), paragraphs.count - 1)
        await tracker.attach(state: state)
        startConsumingPassages()
        startAdvanceWatcher()
        guard await requestActiveMode() else {
            await stop()
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return false
        }
        guard await playCurrent() else {
            await stop()
            await coordinator.unregisterHandlers(for: .tts, ownerID: sessionToken)
            return false
        }
        return true
    }

    private func startAdvanceWatcher() {
        advanceWatcher.start(targetPassageId: String(currentIndex)) {
            [weak self] in
            await self?.advance()
        }
    }

    func stop(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        
        consumeTask?.cancel()
        consumeTask = nil
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        guard lease?.isValid ?? true else { return }
        // A reader can be reopened before an older controller finishes its
        // async teardown. Cancel this bridge's work, but never stop the
        // shared engine after a replacement session has claimed ownership.
        if state.ownsPlaybackSession(sessionToken) {
            await engine.stop(lease: lease ?? TTSAlwaysValidLease())
        }
        guard lease?.isValid ?? true else { return }
        await tracker.detach()
        paragraphs = []
        currentIndex = 0
        onPassageChange(nil)
    }

    func pause(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        
        await readAhead.cancelAll()
        guard lease?.isValid ?? true else { return }
        await engine.pause(lease: lease ?? TTSAlwaysValidLease())
        guard lease?.isValid ?? true else { return }
        state.update(status: .paused)
        
        
    }
    private func requestActiveMode(lease: RemoteCommandLease? = nil) async -> Bool {
        guard lease?.isValid ?? true else { return false }
        await coordinator.registerPreemption(for: .tts, ownerID: sessionToken) { [weak self] in
            await self?.pause()
        }
        await coordinator.registerRecovery(for: .tts, ownerID: sessionToken) { [weak self] in
            await self?.resume()
        }
        await coordinator.registerSuspension(for: .tts, ownerID: sessionToken) { [weak self] in
            await self?.pause()
        }
        guard lease?.isValid ?? true else { return false }
        return await coordinator.requestActiveMode(.tts)
    }

    func resume(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        guard await requestActiveMode(lease: lease) else { return }
        guard lease?.isValid ?? true else { return }
        await engine.resume(lease: lease ?? TTSAlwaysValidLease())
        guard lease?.isValid ?? true else { return }
        state.update(status: .playing)
    }

    func jump(to index: Int, lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        guard index >= 0, index < paragraphs.count else { return }

        advanceWatcher.cancel()
        await readAhead.cancelAll()
        guard lease?.isValid ?? true else { return }

        currentIndex = index
        startAdvanceWatcher()
        await playCurrent(lease: lease)
    }
    
    var currentState:TTSPlaybackState {
        state
    }

    func next(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        if currentIndex + 1 >= paragraphs.count {

            await advanceToNextBatch(lease: lease)
        } else {
            await jump(to: currentIndex + 1, lease: lease)
        }
    }

    func previous(lease: RemoteCommandLease? = nil) async {
        guard lease?.isValid ?? true else { return }
        if currentIndex == 0 {
            await retreatToPreviousBatch(lease: lease)
        } else {
            await jump(to: currentIndex - 1, lease: lease)
        }
    }

    func repeatCurrent() async {
        await jump(to: currentIndex)
    }

    private func startConsumingPassages() {
        consumeTask?.cancel()
    

        consumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.tracker.passageStream()
            for await passageId in stream {
                guard let index = Int(passageId) else { continue }
                self.onPassageChange(index)
            }
        }
    }

    private func playCurrent(lease: RemoteCommandLease? = nil) async -> Bool {
        guard lease?.isValid ?? true else { return false }
        guard currentIndex < paragraphs.count else { return false }
        let settings = await settingsStore.load(userId: userId)

        guard lease?.isValid ?? true else { return false }
        guard currentIndex < paragraphs.count else { return false }
        let paragraph = paragraphs[currentIndex]
        let request = TTSStreamRequest(
            text: paragraph,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed,
            passageId: String(currentIndex),
            sessionToken: sessionToken,
            utteranceToken: UUID(),
            requestToken: UUID()
        )

        await readAhead.warm(
            after: currentIndex,
            in: paragraphs,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
        guard lease?.isValid ?? true else { return false }
        await engine.start(request: request, lease: lease ?? TTSAlwaysValidLease())
        guard lease?.isValid ?? true else { return false }
        // Engines retain terminal failures. Do not turn a failed request into
        // apparent playback while the bridge is awaiting its completion.
        if state.typedFailure == nil, state.status != .error {
            state.update(status: .playing)
        }
        return state.typedFailure == nil && state.status != .error
    }

    private func advance() async {
        currentIndex += 1
        if currentIndex >= paragraphs.count {

            await advanceToNextBatch()
        } else {
            startAdvanceWatcher()
            await playCurrent()
        }
    }

    @discardableResult
    private func advanceToNextBatch(lease: RemoteCommandLease? = nil) async -> Bool {
        guard lease?.isValid ?? true else { return false }
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        guard lease?.isValid ?? true else { return false }
        let next = await onParagraphsExhausted()
        guard lease?.isValid ?? true else { return false }
        guard !next.isEmpty else {
            await stop(lease: lease)
            return false
        }
        paragraphs = next
        currentIndex = 0
        startAdvanceWatcher()
        await playCurrent(lease: lease)
        return true
    }

    @discardableResult
    private func retreatToPreviousBatch(lease: RemoteCommandLease? = nil) async -> Bool {
        guard lease?.isValid ?? true else { return false }
        let previous = await onParagraphsBeforeStart()
        guard lease?.isValid ?? true else { return false }
        guard !previous.isEmpty else { return false }
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        paragraphs = previous
        currentIndex = previous.count - 1
        startAdvanceWatcher()
        await playCurrent(lease: lease)
        return true
    }
}
