import Foundation
import ReadiumNavigator
import ReadiumShared
import RishiAudio
import RishiCore
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
        let utterance = TTSUtterance(
            text: "A remote paragraph.",
            delay: 0,
            voiceOrLanguage: .left(englishVoice)
        )

        let result = await engine.speak(utterance) { _ in }
        let request = await player.request

        #expect(result.isSuccess)
        #expect(request?.text == utterance.text)
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
        let utterance = TTSUtterance(
            text: "Bonjour.",
            delay: 0,
            voiceOrLanguage: .right(Language("fr"))
        )

        let result = await engine.speak(utterance) { _ in }

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
        let utterance = TTSUtterance(
            text: "Next prefetched paragraph.",
            delay: 0,
            voiceOrLanguage: .left(englishVoice)
        )

        let completion = SpeakCompletionFlag()
        let speakTask = Task {
            let result = await engine.speak(utterance) { _ in }
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
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}
}

/// Reproduces the cache-hit race: `start` leaves residual `.stopped` uncleared
/// until `finishPlayback()` advances loading/playing/stopped.
private actor CacheHitRaceTTSPlayer: TTSPlaying {
    let state: TTSPlaybackState
    private(set) var startCount = 0

    init(state: TTSPlaybackState) {
        self.state = state
    }

    func start(request: TTSStreamRequest) async {
        startCount += 1
        // Intentionally do not clear `.stopped` — old cache-hit behavior.
    }

    func finishPlayback() async {
        await MainActor.run {
            state.update(status: .loading)
            state.update(status: .playing)
            state.update(status: .stopped)
        }
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
