import Testing
import Foundation
@testable import rishi
import RishiSettings

@MainActor
@Suite("AppReaderDefaults.voiceLanguage")
struct AppVoiceDefaultsLanguageTests {

    private func makeSuite() -> (UserDefaults, String) {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test("absent key reads English on first run")
    func absentKeyDefaultsToEnglish() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = AppReaderDefaults(defaults: defaults)
        #expect(prefs.voiceLanguage == .english)
    }

    @Test("explicit selection persists and round-trips")
    func explicitSelectionPersists() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = AppReaderDefaults(defaults: defaults)
        prefs.voiceLanguage = .spanish

        #expect(prefs.voiceLanguage == .spanish)
        #expect(defaults.string(forKey: "voice.language") == VoiceLanguageOption.spanish.rawValue)
    }
}
