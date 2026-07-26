@testable import rishi
import Testing
import Foundation
import SwiftUI


@Suite("ReaderTheme")
struct ReaderThemeTests {

    @Test("Raw values are stable for persistence")
    func rawValuesAreStable() {
        #expect(ReaderTheme.matchDevice.rawValue == "matchDevice")
        #expect(ReaderTheme.light.rawValue == "light")
        #expect(ReaderTheme.sepia.rawValue == "sepia")
        #expect(ReaderTheme.dark.rawValue == "dark")
    }

    @Test("allCases has exactly four themes in declared order")
    func allCasesIsExhaustive() {
        #expect(ReaderTheme.allCases == [.matchDevice, .light, .sepia, .dark])
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        for theme in ReaderTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(ReaderTheme.self, from: data)
            #expect(decoded == theme)
        }
    }

    @Test("Default is .matchDevice")
    func defaultIsMatchDevice() {
        #expect(ReaderTheme.default == .matchDevice)
    }

    @Test("resolved(isDark:) maps matchDevice to light or dark")
    func resolvedMatchDevice() {
        #expect(ReaderTheme.matchDevice.resolved(isDark: false) == .light)
        #expect(ReaderTheme.matchDevice.resolved(isDark: true) == .dark)
        #expect(ReaderTheme.light.resolved(isDark: true) == .light)
        #expect(ReaderTheme.sepia.resolved(isDark: true) == .sepia)
        #expect(ReaderTheme.dark.resolved(isDark: false) == .dark)
    }

    @Test("preferredColorScheme maps themes for chrome")
    func preferredColorSchemeMapping() {
        #expect(ReaderTheme.matchDevice.preferredColorScheme == nil)
        #expect(ReaderTheme.light.preferredColorScheme == .light)
        #expect(ReaderTheme.sepia.preferredColorScheme == .light)
        #expect(ReaderTheme.dark.preferredColorScheme == .dark)
    }
}
