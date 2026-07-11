import Testing
import Foundation
@testable import rishi
import RishiSettings

@MainActor
@Suite("AppVoiceDefaults.language")
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

        let prefs = AppVoiceDefaults(defaults: defaults)
        #expect(prefs.language == .english)
    }

    @Test("explicit selection persists and round-trips")
    func explicitSelectionPersists() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = AppVoiceDefaults(defaults: defaults)
        prefs.language = .spanish

        #expect(prefs.language == .spanish)
        #expect(defaults.string(forKey: "voice.defaults.language") == VoiceLanguageOption.spanish.rawValue)
    }
}
