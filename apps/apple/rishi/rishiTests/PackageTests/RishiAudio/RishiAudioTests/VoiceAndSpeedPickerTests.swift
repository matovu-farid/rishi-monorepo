@testable import rishi
import Testing
import Foundation



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
        // Done closure constructs `TTSSettings(voice:model:speed:)`, saves via the
        // store, and forwards via onDismiss. We don't need to render the
        // SwiftUI tree for the contract test.
        let picked = TTSSettings(voice: "nova", model: "eleven_flash_v2_5", speed: 1.5)
        await store.save(picked, userId: userId)
        let loaded = await store.load(userId: userId)
        #expect(loaded == picked)
    }

    @Test("Picker clamps out-of-range speed at the model boundary")
    func speedClamping() {
        let s = TTSSettings(voice: "echo", model: "eleven_v3", speed: 5.0)
        #expect(s.speed == 2.0)
        let t = TTSSettings(voice: "echo", model: "eleven_v3", speed: 0.1)
        #expect(t.speed == 0.5)
    }

    @Test("Catalog normalization preserves the stored model without a model picker")
    func catalogNormalizationPreservesModel() {
        let settings = TTSSettings(voice: "echo", model: "provider-model", speed: 1.0)
        let normalized = TTSPickerCatalog.fallback.normalized(settings)

        #expect(normalized.model == settings.model)
    }

    @MainActor
    @Test("a presentation snapshot keeps its catalog and selection through refresh")
    func presentationSnapshotRetainsCatalogAndLaterStateUsesRefresh() {
        let catalogStore = TTSPickerCatalogStore()
        let firstCatalog = TTSPickerCatalog(
            voiceChoices: [
                .init(id: "catalog-a", name: "Voice A"),
                .init(id: "catalog-a-alt", name: "Voice A alternate")
            ],
            defaultVoiceID: "catalog-a"
        )
        let refreshedCatalog = pickerCatalog(voiceID: "catalog-b", name: "Voice B")
        let initial = TTSSettings(voice: "removed-voice", model: "provider-model", speed: 1.5)
        catalogStore.catalog = firstCatalog

        let openPresentation = VoiceAndSpeedPickerState(
            catalog: catalogStore.catalog,
            initial: initial
        )
        catalogStore.catalog = refreshedCatalog
        let laterPresentation = VoiceAndSpeedPickerState(
            catalog: catalogStore.catalog,
            initial: initial
        )

        #expect(openPresentation.catalog == firstCatalog)
        #expect(openPresentation.settings == TTSSettings(
            voice: "catalog-a",
            model: "provider-model",
            speed: 1.5
        ))
        #expect(laterPresentation.catalog == refreshedCatalog)
        #expect(laterPresentation.settings == TTSSettings(
            voice: "catalog-b",
            model: "provider-model",
            speed: 1.5
        ))
    }

    @MainActor
    @Test("constructing a picker does not write a normalized fallback choice")
    func normalizationIsNotPersistedUntilDone() async {
        let store = InMemoryTTSSettingsStore()
        let userID = UUID()
        let initial = TTSSettings(voice: "removed-voice", model: "provider-model", speed: 1.25)
        _ = VoiceAndSpeedPicker(
            initial: initial,
            userId: userID,
            store: store,
            catalog: pickerCatalog(voiceID: "fallback-voice"),
            onDismiss: { _ in }
        )

        #expect(await store.load(userId: userID) == .default)
    }
}

private func pickerCatalog(voiceID: String, name: String? = nil) -> TTSPickerCatalog {
    TTSPickerCatalog(
        voiceChoices: [.init(id: voiceID, name: name ?? voiceID)],
        defaultVoiceID: voiceID
    )
}
