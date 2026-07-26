@testable import rishi
import Testing


@Suite("SystemAudioRoutePicker")
struct SystemAudioRoutePickerTests {

    @MainActor
    @Test("Construction does not crash")
    func construction() {
        _ = SystemAudioRoutePicker()
    }
}
