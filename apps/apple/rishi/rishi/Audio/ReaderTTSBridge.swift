import Foundation
import Observation
import RishiAudio
import RishiCore

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
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] }
    ) {
        self.engine = engine
        self.state = state
        self.tracker = tracker
        self.settingsStore = settingsStore
        self.userId = userId
        self.onPassageChange = onPassageChange
        self.onParagraphsExhausted = onParagraphsExhausted
        self.onParagraphsBeforeStart = onParagraphsBeforeStart

        self.advanceWatcher = ParagraphAdvanceWatcher(state: state)
        self.readAhead = ReadAheadCoordinator(prewarmer: prewarmer)
        self.coordinator = coordinator
    }
    
   

    func start(paragraphs: [String], startIndex: Int = 0) async {
        await stop()
        guard !paragraphs.isEmpty else { return }
        self.paragraphs = paragraphs
        self.currentIndex = min(max(startIndex, 0), paragraphs.count - 1)
        await tracker.attach(state: state)
        startConsumingPassages()
        startAdvanceWatcher()
        await requestActiveMode()
        await playCurrent()

    }

    private func startAdvanceWatcher() {
        advanceWatcher.start(targetPassageId: String(currentIndex)) {
            [weak self] in
            await self?.advance()
        }
    }

    func stop() async {
        
        consumeTask?.cancel()
        consumeTask = nil
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        await engine.stop()
        await tracker.detach()
        paragraphs = []
        currentIndex = 0
        onPassageChange(nil)
        state.update(status: .stopped)
    }

    func pause() async {
        
        await readAhead.cancelAll()
        await engine.pause()
        state.update(status: .paused)
        
        
    }
    private func requestActiveMode()async{
        await coordinator.registerPreemption(for: .tts) { [weak self] in
            await self?.pause()
        }
        await coordinator.registerSuspension(for: .tts) { [weak self] in
            await self?.pause()
        }
        await coordinator.requestActiveMode(.tts)
    }

    func resume() async {
        await requestActiveMode()
        await engine.resume()
        state.update(status: .playing)
    }

    func jump(to index: Int) async {
        guard index >= 0, index < paragraphs.count else { return }

        advanceWatcher.cancel()
        await readAhead.cancelAll()

        currentIndex = index
        startAdvanceWatcher()
        await playCurrent()
    }
    
    var currentState:TTSPlaybackState {
        state
    }

    func next() async {
        if currentIndex + 1 >= paragraphs.count {

            await advanceToNextBatch()
        } else {
            await jump(to: currentIndex + 1)
        }
    }

    func previous() async {
        if currentIndex == 0 {
            await retreatToPreviousBatch()
        } else {
            await jump(to: currentIndex - 1)
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

    private func playCurrent() async {
        guard currentIndex < paragraphs.count else { return }
        let settings = await settingsStore.load(userId: userId)

        guard currentIndex < paragraphs.count else { return }
        let paragraph = paragraphs[currentIndex]
        let request = TTSStreamRequest(
            text: paragraph,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed,
            passageId: String(currentIndex)
        )

        await readAhead.warm(
            after: currentIndex,
            in: paragraphs,
            voice: settings.voice,
            model: settings.model,
            speed: settings.speed
        )
        await engine.start(request: request)
        state.update(status: .playing)
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
    private func advanceToNextBatch() async -> Bool {
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        let next = await onParagraphsExhausted()
        guard !next.isEmpty else {
            await stop()
            return false
        }
        paragraphs = next
        currentIndex = 0
        startAdvanceWatcher()
        await playCurrent()
        return true
    }

    @discardableResult
    private func retreatToPreviousBatch() async -> Bool {
        let previous = await onParagraphsBeforeStart()
        guard !previous.isEmpty else { return false }
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        paragraphs = previous
        currentIndex = previous.count - 1
        startAdvanceWatcher()
        await playCurrent()
        return true
    }
}


