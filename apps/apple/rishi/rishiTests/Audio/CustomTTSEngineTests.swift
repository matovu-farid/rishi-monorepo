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
}

private actor RecordingTTSPlayer: TTSPlaying {
    let state: TTSPlaybackState
    private(set) var request: TTSStreamRequest?

    init(state: TTSPlaybackState) {
        self.state = state
    }

    func start(request: TTSStreamRequest) async {
        self.request = request
        await MainActor.run { state.update(status: .stopped) }
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
