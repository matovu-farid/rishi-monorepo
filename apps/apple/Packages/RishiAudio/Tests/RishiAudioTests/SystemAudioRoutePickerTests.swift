import Testing
@testable import RishiAudio

@Suite("SystemAudioRoutePicker")
struct SystemAudioRoutePickerTests {

    @MainActor
    @Test("Construction does not crash")
    func construction() {
        _ = SystemAudioRoutePicker()
    }
}
