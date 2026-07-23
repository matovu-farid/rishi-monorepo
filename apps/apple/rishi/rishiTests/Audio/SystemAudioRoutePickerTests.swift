import Testing
@testable import rishi

@Suite("System audio route picker")
struct SystemAudioRoutePickerTests {

    @Test("route picker is offered only while TTS is active")
    func visibilityFollowsTTSSession() {
        #expect(SystemAudioRoutePickerVisibility.shouldShow(ttsActive: true))
        #expect(SystemAudioRoutePickerVisibility.shouldShow(ttsActive: false) == false)
    }
}
