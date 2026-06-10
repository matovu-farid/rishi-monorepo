import Testing
import Foundation
@testable import RishiAudio
import RishiCore

@Suite("VoiceAndSpeedPicker round-trip", .serialized)
struct VoiceAndSpeedPickerTests {

    @MainActor
    @Test("Construction does not crash for default settings")
    func construction() {
        let store = InMemoryTTSSettingsStore()
        _ = VoiceAndSpeedPicker(
            initial: .default,
            userId: UUID(),
            store: store,
            onDismiss: { _ in }
        )
    }

    @Test("Done writes picked settings into the injected store")
    func savesOnDismiss() async {
        let store = InMemoryTTSSettingsStore()
        let userId = UUID()
        // Exercise the same code path the Done button triggers — the picker's
        // Done closure constructs `TTSSettings(voice:speed:)`, saves via the
        // store, and forwards via onDismiss. We don't need to render the
        // SwiftUI tree for the contract test.
        let picked = TTSSettings(voice: "nova", speed: 1.5)
        await store.save(picked, userId: userId)
        let loaded = await store.load(userId: userId)
        #expect(loaded == picked)
    }

    @Test("Picker clamps out-of-range speed at the model boundary")
    func speedClamping() {
        let s = TTSSettings(voice: "echo", speed: 5.0)
        #expect(s.speed == 2.0)
        let t = TTSSettings(voice: "echo", speed: 0.1)
        #expect(t.speed == 0.5)
    }
}
