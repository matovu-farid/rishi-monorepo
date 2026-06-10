import Testing
import Foundation
@testable import RishiReader

@Suite("Reader typography value types")
struct ReaderTypographyTests {

    @Test("ReaderFontFamily raw values are stable for sync")
    func fontFamilyRawValues() {
        #expect(ReaderFontFamily.system.rawValue == "system")
        #expect(ReaderFontFamily.serif.rawValue == "serif")
        #expect(ReaderFontFamily.sans.rawValue == "sans")
        #expect(ReaderFontFamily.dyslexic.rawValue == "dyslexic")
    }

    @Test("ReaderFontSize clamps to [12, 32]")
    func fontSizeClamps() {
        #expect(ReaderFontSize(points: 5).points == 12)
        #expect(ReaderFontSize(points: 100).points == 32)
        #expect(ReaderFontSize(points: 17).points == 17)
    }

    @Test("ReaderLineHeight clamps to [1.0, 2.0]")
    func lineHeightClamps() {
        #expect(ReaderLineHeight(multiplier: 0.5).multiplier == 1.0)
        #expect(ReaderLineHeight(multiplier: 5).multiplier == 2.0)
        #expect(ReaderLineHeight(multiplier: 1.4).multiplier == 1.4)
    }

    @Test("ReaderTypography.default uses the three value-type defaults")
    func typographyDefaultComposition() {
        let t = ReaderTypography.default
        #expect(t.fontFamily == .system)
        #expect(t.lineHeight.multiplier == 1.4)
        // Font size default is Dynamic-Type-derived on UIKit; on host it's 17.
        // Just assert it's inside the clamp window.
        #expect(t.fontSize.points >= ReaderFontSize.min)
        #expect(t.fontSize.points <= ReaderFontSize.max)
    }

    @Test("ReaderTypography Codable round-trip")
    func codableRoundTrip() throws {
        let original = ReaderTypography(
            fontFamily: .serif,
            fontSize: ReaderFontSize(points: 20),
            lineHeight: ReaderLineHeight(multiplier: 1.6)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReaderTypography.self, from: data)
        #expect(decoded == original)
    }
}
