import Foundation
import ReadiumNavigator
import ReadiumShared


import Testing
@testable import rishi

@Suite("Custom TTS engine")
@MainActor
struct CustomTTSEngineTests {
    private let englishVoice = TTSVoice(
        identifier: "custom-english",
        language: Language("en-US"),
        name: "Custom English",
        gender: .unspecified,
        quality: .high
    )

    @Test("forwards custom voice, model, and speed to remote playback")
    func forwardsRemoteRequest() async {
        let state = TTSPlaybackState()
        let player = RecordingTTSPlayer(state: state)
        let userId = UserID()
        let settings = InMemoryTTSSettingsStore()
        await settings.save(
            TTSSettings(voice: englishVoice.identifier, model: "custom-model", speed: 1.25),
            userId: userId
        )
        let engine = CustomTTSEngine(
            player: player,
            state: state,
            settingsStore: settings,
            userId: userId,
            voices: [englishVoice]
        )
        let text = "A remote paragraph."
        let result = await engine.speak(
            text: text,
            delay: 0,
            voiceOrLanguage: .left(englishVoice)
        ) { _ in }
        let request = await player.request

        #expect(result.isSuccess)
        #expect(request?.text == text)
        #expect(request?.voice == englishVoice.identifier)
        #expect(request?.model == "custom-model")
        #expect(request?.speed == 1.25)
    }

    @Test("returns a language error when no remote voice supports the language")
    func rejectsUnsupportedLanguage() async {
        let state = TTSPlaybackState()
        let player = RecordingTTSPlayer(state: state)
        let engine = CustomTTSEngine(
            player: player,
            state: state,
            settingsStore: InMemoryTTSSettingsStore(),
            userId: UserID(),
            voices: [englishVoice]
        )
        let result = await engine.speak(
            text: "Bonjour.",
            delay: 0,
            voiceOrLanguage: .right(Language("fr"))
        ) { _ in }

        guard case let .failure(.languageNotSupported(language, _)) = result else {
            Issue.record("Expected a languageNotSupported error, got \(result)")
            return
        }
        #expect(language == Language("fr"))
    }

    @Test("does not treat residual .stopped as completion before playback starts (cache-hit race)")
    func ignoresResidualStoppedUntilPlaybackCompletes() async {
        let state = TTSPlaybackState()
        state.update(status: .stopped)

        let player = CacheHitRaceTTSPlayer(state: state)
        let engine = CustomTTSEngine(
            player: player,
            state: state,
            settingsStore: InMemoryTTSSettingsStore(),
            userId: UserID(),
            voices: [englishVoice]
        )
        let completion = SpeakCompletionFlag()
        let speakTask = Task {
            let result = await engine.speak(
                text: "Next prefetched paragraph.",
                delay: 0,
                voiceOrLanguage: .left(englishVoice)
            ) { _ in }
            await completion.markDone()
            return result
        }

        // Residual `.stopped` must not complete speak immediately.
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(await completion.isDone() == false)
        #expect(await player.startCount == 1)

        await player.finishPlayback()
        let result = await speakTask.value
        #expect(await completion.isDone() == true)
        #expect(result.isSuccess)
    }

    @Test("speak fails when engine reports finish without play even if ttsState was .playing")
    func speakFailsWhenEngineRejectsFinishWithoutPlay() async {
        let state = TTSPlaybackState()
        state.update(status: .playing) // dual-writer already stamped
        let engine = CustomTTSEngine(
            player: FinishWithoutPlayPlayer(state: state),
            state: state,
            settingsStore: InMemoryTTSSettingsStore(),
            userId: UserID(),
            voices: [englishVoice]
        )
        let result = await engine.speak(
            text: "Must not advance.",
            delay: 0,
            voiceOrLanguage: .left(englishVoice)
        ) { _ in }
        guard case .failure = result else {
            Issue.record("Expected failure so Readium does not playNextUtterance")
            return
        }
    }
}

private actor SpeakCompletionFlag {
    private var done = false
    func markDone() { done = true }
    func isDone() -> Bool { done }
}

/// Happy-path double: runs a full loading → stopped cycle so speak can finish.
private actor RecordingTTSPlayer: TTSPlaying {
    let state: TTSPlaybackState
    private(set) var request: TTSStreamRequest?
    private var pendingResult: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    init(state: TTSPlaybackState) {
        self.state = state
    }

    func start(request: TTSStreamRequest) async {
        self.request = request
        await MainActor.run {
            state.update(status: .loading)
            state.update(status: .playing)
            state.update(status: .stopped)
        }
        settle(.success(()))
    }

    func waitUntilFinished() async throws {
        if let pending = pendingResult {
            pendingResult = nil
            try pending.get()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let pending = pendingResult {
                pendingResult = nil
                continuation.resume(with: pending)
                return
            }
            waiter = continuation
        }
    }

    func pause() async {}
    func resume() async {}
    func stop() async {
        settle(.failure(CancellationError()))
    }

    private func settle(_ result: Result<Void, Error>) {
        if let waiter {
            self.waiter = nil
            pendingResult = nil
            waiter.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

/// Reproduces the cache-hit race: `start` leaves residual `.stopped` uncleared
/// until `finishPlayback()` advances loading/playing/stopped.
private actor CacheHitRaceTTSPlayer: TTSPlaying {
    let state: TTSPlaybackState
    private(set) var startCount = 0
    private var pendingResult: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    init(state: TTSPlaybackState) {
        self.state = state
    }

    func start(request: TTSStreamRequest) async {
        startCount += 1
        // Intentionally do not clear `.stopped` — old cache-hit behavior.
        // Completion is deferred until finishPlayback().
    }

    func finishPlayback() async {
        await MainActor.run {
            state.update(status: .loading)
            state.update(status: .playing)
            state.update(status: .stopped)
        }
        settle(.success(()))
    }

    func waitUntilFinished() async throws {
        if let pending = pendingResult {
            pendingResult = nil
            try pending.get()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let pending = pendingResult {
                pendingResult = nil
                continuation.resume(with: pending)
                return
            }
            waiter = continuation
        }
    }

    func pause() async {}
    func resume() async {}
    func stop() async {
        settle(.failure(CancellationError()))
    }

    private func settle(_ result: Result<Void, Error>) {
        if let waiter {
            self.waiter = nil
            pendingResult = nil
            waiter.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

private actor FinishWithoutPlayPlayer: TTSPlaying {
    let state: TTSPlaybackState
    init(state: TTSPlaybackState) { self.state = state }

    func start(request: TTSStreamRequest) async {
        // Mimic synthesizer dual-write contamination on shared UI state:
        await MainActor.run {
            state.update(status: .playing) // synthesizer stamp
            state.update(status: .stopped) // empty finish
        }
    }

    func waitUntilFinished() async throws {
        // Engine contract: no didStart → failure (do not inspect state.status)
        throw NSError(
            domain: "TTSEnginePlayback",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "finished without playing"]
        )
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}
}

private extension Result where Failure == TTSError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
