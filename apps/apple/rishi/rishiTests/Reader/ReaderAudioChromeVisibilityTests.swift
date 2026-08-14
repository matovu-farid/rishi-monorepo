import Testing
@testable import rishi

@Suite("ReaderAudioChrome visibility")
struct ReaderAudioChromeVisibilityTests {

    @Test("voice overlay visible when isPresenting even without prior TTS")
    func voiceOnlyShowsChrome() {
        #expect(ReaderAudioChromeVisibility.shouldShow(voiceActive: true, ttsVisible: false))
    }

    @Test("overlay hidden when neither voice nor TTS active")
    func hiddenWhenIdle() {
        #expect(ReaderAudioChromeVisibility.shouldShow(voiceActive: false, ttsVisible: false) == false)
    }

    @Test("overlay visible for TTS alone")
    func ttsShowsChrome() {
        #expect(ReaderAudioChromeVisibility.shouldShow(voiceActive: false, ttsVisible: true))
    }
}
