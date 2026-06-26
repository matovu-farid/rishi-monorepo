









import Testing
import Foundation
@testable import rishi

@MainActor
@Suite("AppReaderDefaults.autoSync")
struct AppReaderDefaultsAutoSyncTests {

    
    
    private func makeSuite() -> (UserDefaults, String) {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test("absent key reads ON (default true preserves upgrade behavior)")
    func absentKeyDefaultsOn() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = AppReaderDefaults(defaults: defaults)

        
        
        #expect(prefs.autoSync == true)
    }

    @Test("explicit false survives (not coerced to the default)")
    func explicitFalseSurvives() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = AppReaderDefaults(defaults: defaults)
        prefs.autoSync = false

        #expect(prefs.autoSync == false)
    }

    @Test("explicit true reads true and writes the backing key")
    func explicitTrueWritesKey() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = AppReaderDefaults(defaults: defaults)
        prefs.autoSync = true

        #expect(prefs.autoSync == true)
        #expect(defaults.object(forKey: "reader.defaults.autoSync") != nil)
    }
}
