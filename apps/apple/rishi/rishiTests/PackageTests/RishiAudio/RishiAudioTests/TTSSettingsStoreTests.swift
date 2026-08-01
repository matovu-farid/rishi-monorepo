@testable import rishi
import Testing
import Foundation



@Suite("TTSSettings + TTSSettingsStore", .serialized)
struct TTSSettingsStoreTests {

    @Test("Default is marin @ 1.0")
    func defaultIsMarin() {
        let s = TTSSettings.default
        #expect(s.voice == "marin")
        #expect(s.model == TTSModelCatalog.defaultModel)
        #expect(s.speed == 1.0)
    }

    @Test("Speed clamps below 0.5")
    func speedClampsLow() {
        let s = TTSSettings(voice: "alloy", model: "eleven_v3", speed: 0.1)
        #expect(s.speed == 0.5)
    }

    @Test("Speed clamps above 2.0")
    func speedClampsHigh() {
        let s = TTSSettings(voice: "alloy", model: "eleven_v3", speed: 3.0)
        #expect(s.speed == 2.0)
    }

    @Test("InMemoryTTSSettingsStore round-trips")
    func inMemoryRoundTrip() async {
        let store = InMemoryTTSSettingsStore()
        let userId = UUID()
        let settings = TTSSettings(voice: "nova", model: "eleven_flash_v2_5", speed: 1.5)
        await store.save(settings, userId: userId)
        let loaded = await store.load(userId: userId)
        #expect(loaded == settings)
    }

    @Test("Two userIds get two independent settings")
    func perUserIsolation() async {
        let store = InMemoryTTSSettingsStore()
        let a = UUID()
        let b = UUID()
        await store.save(TTSSettings(voice: "alloy", model: "eleven_v3", speed: 0.75), userId: a)
        await store.save(TTSSettings(voice: "fable", model: "eleven_flash_v2", speed: 1.25), userId: b)
        let loadedA = await store.load(userId: a)
        let loadedB = await store.load(userId: b)
        #expect(loadedA.voice == "alloy")
        #expect(loadedB.voice == "fable")
    }

    @Test("UserDefaultsTTSSettingsStore round-trips via a private suite")
    func userDefaultsRoundTrip() async {
        let suiteName = "RishiAudio.TTSSettings.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsTTSSettingsStore(defaults: defaults)
        let userId = UUID()
        let settings = TTSSettings(voice: "shimmer", model: "eleven_multilingual_v2", speed: 1.75)
        await store.save(settings, userId: userId)
        let loaded = await store.load(userId: userId)
        #expect(loaded == settings)
    }

    @Test("UserDefaultsTTSSettingsStore returns .default for unseen user")
    func userDefaultsReturnsDefault() async {
        let defaults = UserDefaults(suiteName: "RishiAudio.TTSSettings.Tests.empty.\(UUID().uuidString)")!
        let store = UserDefaultsTTSSettingsStore(defaults: defaults)
        let loaded = await store.load(userId: UUID())
        #expect(loaded == .default)
    }

    @Test("Account deletion removes only the deleted user's settings")
    func removeIsPerUser() async {
        let store = InMemoryTTSSettingsStore()
        let deletedUser = UUID()
        let retainedUser = UUID()
        let settings = TTSSettings(voice: "shimmer", model: "eleven_v3", speed: 1.25)
        await store.save(settings, userId: deletedUser)
        await store.save(settings, userId: retainedUser)

        await store.remove(userId: deletedUser)

        #expect(await store.load(userId: deletedUser) == .default)
        #expect(await store.load(userId: retainedUser) == settings)
    }

    @Test("UserDefaults account deletion removes the user's settings")
    func userDefaultsRemove() async {
        let suiteName = "RishiAudio.TTSSettings.Tests.remove.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTTSSettingsStore(defaults: defaults)
        let userId = UUID()
        await store.save(TTSSettings(voice: "nova", model: "eleven_v3", speed: 1.1), userId: userId)

        await store.remove(userId: userId)

        #expect(await store.load(userId: userId) == .default)
    }

    @Test("Key shape is per-user")
    func keyShape() {
        let userId = UUID()
        let key = UserDefaultsTTSSettingsStore.key(for: userId)
        #expect(key == "tts.settings.\(userId.uuidString)")
    }
}
