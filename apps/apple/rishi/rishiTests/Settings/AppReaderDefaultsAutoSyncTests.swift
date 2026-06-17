//
//  AppReaderDefaultsAutoSyncTests.swift
//  rishiTests
//
//  Phase 33 Plan 33-01 — pins the NEW persisted Auto Sync flag on
//  `AppReaderDefaults`. Auto Sync defaults ON so existing users keep
//  syncing on upgrade: an ABSENT UserDefaults key must read `true`, NOT
//  the `bool(forKey:)` default of `false` (Pitfall 4). Swift Testing only.
//

import Testing
import Foundation
@testable import rishi

@MainActor
@Suite("AppReaderDefaults.autoSync")
struct AppReaderDefaultsAutoSyncTests {

    /// Build a fresh, isolated UserDefaults suite per test so the absent /
    /// explicit-false / explicit-true cases never bleed into one another.
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

        // No write has happened — the key is absent. Must read true, NOT the
        // bool(forKey:) default of false.
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
