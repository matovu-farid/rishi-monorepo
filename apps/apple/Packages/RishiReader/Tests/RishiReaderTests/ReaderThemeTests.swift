import Testing
import Foundation
@testable import RishiReader

@Suite("ReaderTheme")
struct ReaderThemeTests {

    @Test("Raw values are stable for persistence")
    func rawValuesAreStable() {
        #expect(ReaderTheme.light.rawValue == "light")
        #expect(ReaderTheme.sepia.rawValue == "sepia")
        #expect(ReaderTheme.dark.rawValue == "dark")
    }

    @Test("allCases has exactly three themes in declared order")
    func allCasesIsExhaustive() {
        #expect(ReaderTheme.allCases == [.light, .sepia, .dark])
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        for theme in ReaderTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(ReaderTheme.self, from: data)
            #expect(decoded == theme)
        }
    }

    @Test("Default is .light")
    func defaultIsLight() {
        #expect(ReaderTheme.default == .light)
    }
}
