import Foundation
import Testing
import ReadiumShared
@testable import rishi

@Suite("Read aloud terminal recovery")
@MainActor
struct ReadAloudRecoveryTests {
    private func context(onPosition: (@MainActor (Locator) -> Void)? = nil) -> (ReadAloudController, HeldRecoveryEngine, TTSPlaybackState) {
        let state = TTSPlaybackState()
        let engine = HeldRecoveryEngine(state: state)
        let controller = ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: RecoveryEmptySource()),
            ttsPresence: TTSPresenceController(state: state, store: RecoveryPresenceStore()),
            coordidator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
            userId: UserID(),
            onReadAloudPositionChange: onPosition
        )
        return (controller, engine, state)
    }

    private func start(_ controller: ReadAloudController, text: String = "Recovery paragraph") async {
        await controller.start(
            paragraphs: [text], bookID: "recovery-book",
            metadata: NowPlayingMetadata(title: "Recovery"), onPassageChange: { _ in }
        )
    }

    private func waitForGenerationChange(_ controller: ReadAloudController, from generation: UInt64) async {
        for _ in 0..<1000 {
            if controller.playbackGenerationForRecoveryTests != generation { return }
            await Task.yield()
        }
        Issue.record("Playback operation did not reach its admission boundary")
    }

    @Test("Dismiss and Play select restart while terminal cleanup is still held")
    func dismissedFailureStillRestarts() async throws {
        let (controller, engine, state) = context()
        await start(controller)
        await engine.holdNextStop()
        let teardown = try #require(controller.enqueuePlaybackFailureForTests())
        await engine.waitForHeldStop()
        #expect(controller.hasActivePlaybackSession)
        #expect(controller.requiresPlaybackRestart)
        TTSFailureAlert.clear(state)
        #expect(ReaderReadAloudPlayAction.select(controller: controller) == .restart)
        let generation = controller.playbackGenerationForRecoveryTests
        let replacement = Task { await start(controller) }
        await waitForGenerationChange(controller, from: generation)
        #expect(await engine.requests.count == 1)
        await engine.releaseStop()
        await teardown.value
        await replacement.value
        #expect(await engine.requests.count == 2)
        #expect(!controller.requiresPlaybackRestart)
        #expect(ReaderReadAloudPlayAction.select(controller: controller) == .toggle)
        #expect(state.userFacingFailure == nil)
        await controller.stop()
        controller.dispose()
    }

    @Test("typed and generic terminal signals coalesce and a fresh start clears only old failure")
    func terminalSourcesCoalesce() async throws {
        let (controller, engine, state) = context()
        await start(controller)
        let firstRequest = try #require(await engine.requests.first)
        let stopsBeforeFailure = await engine.stopCount
        await engine.holdNextStop()
        let generic = try #require(controller.enqueuePlaybackFailureForTests())
        await engine.waitForHeldStop()
        state.recordTypedFailure(.narration(message: "exhausted"), tokens: firstRequest.tokenSnapshot)
        let duplicate = try #require(controller.enqueuePlaybackFailureForTests())
        let stopsDuringFailure = await engine.stopCount
        #expect(stopsDuringFailure == stopsBeforeFailure + 1)
        let generation = controller.playbackGenerationForRecoveryTests
        let replacement = Task { await start(controller) }
        await waitForGenerationChange(controller, from: generation)
        #expect(await engine.requests.count == 1)
        await engine.releaseStop()
        await generic.value
        await duplicate.value
        await replacement.value
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests[0].sessionToken != requests[1].sessionToken)
        #expect(state.typedFailure == nil)
        #expect(state.status == .playing)
        await controller.stop()
        controller.dispose()
    }

    @Test("typed failure registers cleanup before the generic signal and preserves allowance")
    func typedFirstCoalescesGenericSignal() async throws {
        let (controller, engine, state) = context()
        await start(controller)
        let request = try #require(await engine.requests.first)
        let stopsBeforeFailure = await engine.stopCount
        await engine.holdNextStop()
        state.recordTypedFailure(.narration(message: "exhausted"), tokens: request.tokenSnapshot)
        let generic = try #require(controller.enqueuePlaybackFailureForTests())
        await engine.waitForHeldStop()
        let stopsDuringFailure = await engine.stopCount
        #expect(stopsDuringFailure == stopsBeforeFailure + 1)
        #expect(controller.requiresPlaybackRestart)
        await engine.releaseStop()
        await generic.value
        #expect(state.typedFailure == .narration(message: "exhausted"))
        #expect(state.typedFailureTokens == request.tokenSnapshot)
        await controller.stop()
        #expect(state.typedFailure == nil)
        controller.dispose()
    }

    @Test("stop invalidates a pending restart and cannot resurrect audio after exit")
    func exitInvalidatesPendingRestart() async throws {
        let (controller, engine, state) = context()
        await start(controller)
        await engine.holdNextStop()
        let teardown = try #require(controller.enqueuePlaybackFailureForTests())
        await engine.waitForHeldStop()
        let initialGeneration = controller.playbackGenerationForRecoveryTests
        let restart = Task { await start(controller) }
        await waitForGenerationChange(controller, from: initialGeneration)
        let restartGeneration = controller.playbackGenerationForRecoveryTests
        let stop = Task { await controller.stop() }
        await waitForGenerationChange(controller, from: restartGeneration)
        await engine.releaseStop()
        await teardown.value
        await restart.value
        await stop.value
        #expect(await engine.requests.count == 1)
        #expect(!controller.hasActivePlaybackSession)
        #expect(state.playbackSessionToken == nil)
        controller.dispose()
    }

    @Test("EPUB retry rebuilds from the retained failing paragraph without reopening its reader")
    func epubRetryKeepsNarrationLocator() async throws {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let userID = UserID()
        let book = Book(userId: userID, title: "Alice", formatType: .epub, fileURL: "alice.epub")
        let vm = ReaderViewModel(
            book: book, userId: userID, documentURL: url,
            positionStore: InMemoryPositionStore(), debounceSeconds: 5
        )
        await vm.load()
        _ = try #require(vm.publication)
        let (controller, engine, state) = context(onPosition: { vm.didChangeReadAloudLocation($0) })
        await controller.startReader(vm: vm)
        await engine.waitForRequestCount(1)
        let failedRequest = try #require(await engine.requests.first)
        for _ in 0..<1000 {
            if vm.latestPositionSource == .readAloud { break }
            await Task.yield()
        }
        #expect(vm.latestPositionSource == .readAloud)
        let failedLocator = try #require(await vm.readAloudStartLocator())
        await engine.holdNextStop()
        await engine.failActiveUtterance()
        // The production Readium delegate registers terminal cleanup. This
        // uses no direct controller failure hook or native rendering sleeps.
        // Readium teardown cancels its engine utterance, so await registration.
        await engine.waitForHeldStop()
        #expect(controller.requiresPlaybackRestart)
        TTSFailureAlert.clear(state)
        let generation = controller.playbackGenerationForRecoveryTests
        let retry = Task { await controller.startReader(vm: vm) }
        await waitForGenerationChange(controller, from: generation)
        await engine.releaseStop()
        await retry.value
        await engine.waitForRequestCount(2)
        let requests = await engine.requests
        #expect(requests[1].text == failedRequest.text)
        #expect(requests[1].sessionToken != failedRequest.sessionToken)
        #expect(await vm.readAloudStartLocator() == failedLocator)
        await controller.stop()
        await vm.flush()
        controller.dispose()
    }

    @Test("owner replacement cannot claim audio until the previous EPUB failure has drained")
    func ownerReplacementDrainsOldFailure() async throws {
        try await replaceOwnerAfterHeldFailure(cancelBeforeDrain: false)
    }

    @Test("reader exit revokes a queued owner retry before it can start EPUB speech")
    func queuedOwnerRetryCannotResurrectAfterExit() async throws {
        try await replaceOwnerAfterHeldFailure(cancelBeforeDrain: true)
    }

    @Test("exit during failed candidate teardown cannot restart the previous reader")
    func cancelledFailedCandidateDoesNotFallback() async throws {
        try await replaceOwnerAfterHeldFailure(cancelBeforeDrain: true, failCandidateBeforeExit: true)
    }

    @Test("voice dismissal completion cannot submit narration after its reader exits")
    func voiceHandoffHonorsCancellationAndRevocation() async {
        for cancelTask in [true, false] {
            let gate = RecoveryVoiceEndGate()
            var isCurrent = true
            var opened = false
            let handoff = Task { @MainActor in
                await ReaderVoiceReadAloudHandoff.perform(
                    endVoice: { await gate.wait() },
                    canContinue: { isCurrent },
                    openReadAloud: { opened = true }
                )
            }
            await gate.waitUntilEntered()
            if cancelTask { handoff.cancel() } else { isCurrent = false }
            await gate.release()
            await handoff.value
            #expect(!opened)
        }
    }

    private func replaceOwnerAfterHeldFailure(cancelBeforeDrain: Bool, failCandidateBeforeExit: Bool = false) async throws {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let userID = UserID()
        let book = Book(userId: userID, title: "Alice", formatType: .epub, fileURL: "alice.epub")
        let vm = ReaderViewModel(book: book, userId: userID, documentURL: url, positionStore: InMemoryPositionStore())
        await vm.load()
        _ = try #require(vm.publication)
        let state = TTSPlaybackState()
        let engine = HeldRecoveryEngine(state: state)
        let owner = ReadAloudPlaybackOwner(
            ttsEngine: engine, ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: RecoveryEmptySource()),
            ttsPresence: TTSPresenceController(state: state, store: RecoveryPresenceStore()),
            coordinator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
            nowPlayingController: NowPlayingController(
                infoSurface: FakeNowPlayingInfoSurface(), commandSurface: FakeRemoteCommandSurface()
            )
        )
        let host = UUID()
        let old = owner.makeController(userId: userID, bookFileStorage: nil, onReadAloudPositionChange: { vm.didChangeReadAloudLocation($0) })
        #expect(await owner.start(controller: old, reader: vm, host: host))
        await engine.waitForRequestCount(1)
        if !failCandidateBeforeExit {
            await engine.holdNextStop()
            await engine.failActiveUtterance()
            await engine.waitForHeldStop()
        }
        let replacement = owner.makeController(userId: userID, bookFileStorage: nil, onReadAloudPositionChange: { vm.didChangeReadAloudLocation($0) })
        if failCandidateBeforeExit {
            owner.startReaderForTests = { candidate, _, _, _ in
                await self.start(candidate, text: "Candidate paragraph")
                state.recordUserFacingFailure(.audioPlayback)
                await engine.holdNextStop()
            }
        }
        let oldGeneration = old.playbackGenerationForRecoveryTests
        let candidate = Task { await owner.start(controller: replacement, reader: vm, host: host) }
        if failCandidateBeforeExit {
            await engine.waitForHeldStop()
            #expect(owner.activeController === replacement)
            #expect(await engine.requests.count == 2)
        } else {
            await waitForGenerationChange(old, from: oldGeneration)
            #expect(owner.activeController === old)
            #expect(await engine.requests.count == 1)
        }
        if cancelBeforeDrain { owner.cancelPendingStarts(host: host) }
        await engine.releaseStop()
        let started = await candidate.value
        if cancelBeforeDrain {
            #expect(!started)
            #expect(await engine.requests.count == (failCandidateBeforeExit ? 2 : 1))
            #expect(state.playbackSessionToken == nil)
        } else {
            #expect(started)
            await engine.waitForRequestCount(2)
            #expect(owner.activeController === replacement)
            #expect(state.playbackSessionToken == (await engine.requests.last)?.sessionToken)
        }
        await owner.stop(host: host)
        await vm.flush()
    }

    @Test("generation-fenced reader exit cannot stop a newer same-host binding")
    func oldExitCannotStopNewGeneration() async {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: .holds)
        let owner = ReadAloudPlaybackOwner(
            ttsEngine: engine, ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(),
            ttsPrewarmer: TTSPrewarmer(source: RecoveryEmptySource()),
            ttsPresence: TTSPresenceController(state: state, store: RecoveryPresenceStore()),
            coordinator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
            nowPlayingController: NowPlayingController(
                infoSurface: FakeNowPlayingInfoSurface(), commandSurface: FakeRemoteCommandSurface()
            )
        )
        let host = UUID()
        let old = owner.makeController(userId: UserID(), bookFileStorage: nil)
        await owner.install(controller: old, host: host)
        let exitingGeneration = owner.generation
        let replacement = owner.makeController(userId: UserID(), bookFileStorage: nil)
        await owner.install(controller: replacement, host: host)
        await start(replacement)
        await owner.stop(host: host, ifGeneration: exitingGeneration)
        #expect(owner.activeController === replacement)
        #expect(state.status == .playing)
        await owner.stop(host: host, ifGeneration: owner.generation)
        #expect(owner.activeController == nil)
        #expect(state.playbackSessionToken == nil)
        #expect(engine.calls.last == .stop)
    }
}

private actor HeldRecoveryEngine: TTSPlaying {
    let state: TTSPlaybackState
    private let engine: FakeTTSEngine
    private(set) var requests: [TTSStreamRequest] = []
    private(set) var stopCount = 0
    private var shouldHold = false
    private var heldStop = false
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var playbackWaiter: CheckedContinuation<Void, Error>?
    private var pendingPlaybackError: Error?
    private var activeTokens: TTSPlaybackTokenSnapshot?

    init(state: TTSPlaybackState) {
        self.state = state
        engine = FakeTTSEngine(state: state, script: .holds)
    }
    func start(request: TTSStreamRequest) async {
        requests.append(request)
        activeTokens = request.tokenSnapshot
        pendingPlaybackError = nil
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        for waiter in ready { waiter.continuation.resume() }
        await MainActor.run { state.activate(tokens: request.tokenSnapshot) }
        await engine.start(request: request)
    }
    func pause() async { await engine.pause() }
    func resume() async { await engine.resume() }
    func waitUntilFinished() async throws {
        if let pendingPlaybackError {
            self.pendingPlaybackError = nil
            throw pendingPlaybackError
        }
        try await withCheckedThrowingContinuation { playbackWaiter = $0 }
    }
    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
    func failActiveUtterance() async {
        await MainActor.run { state.recordUserFacingFailure(.audioPlayback) }
        let error = TTSEnginePlaybackError.playbackFailed("injected transient failure")
        if let playbackWaiter {
            self.playbackWaiter = nil
            playbackWaiter.resume(throwing: error)
        } else {
            pendingPlaybackError = error
        }
    }
    func stop(ifCurrent tokens: TTSPlaybackTokenSnapshot) async {
        guard activeTokens == tokens else { return }
        activeTokens = nil
        await stop()
    }
    func stop() async {
        activeTokens = nil
        stopCount += 1
        if shouldHold {
            shouldHold = false
            heldStop = true
            for waiter in enteredWaiters { waiter.resume() }
            enteredWaiters = []
            await withCheckedContinuation { stopWaiter = $0 }
        }
        if let playbackWaiter {
            self.playbackWaiter = nil
            playbackWaiter.resume(throwing: CancellationError())
        }
        await engine.stop()
    }
    func holdNextStop() { shouldHold = true }
    func waitForHeldStop() async {
        if heldStop { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func releaseStop() {
        heldStop = false
        let waiter = stopWaiter
        stopWaiter = nil
        waiter?.resume()
    }
}

private struct RecoveryEmptySource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
private final class RecoveryPresenceStore: TTSPresenceStore, @unchecked Sendable {
    func read() -> TTSPresenceSnapshot? { nil }
    func write(_ snapshot: TTSPresenceSnapshot) {}
    func clear() {}
}

private actor RecoveryVoiceEndGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}
