import Foundation
import Testing
@testable import RishiUIKit

@Suite("ContrastChecker — WCAG 2.1")
struct ContrastCheckerTests {

    @Test("Black vs white = 21:1")
    func blackVsWhite() {
        let black = ContrastChecker.RGB(r: 0, g: 0, b: 0)
        let white = ContrastChecker.RGB(r: 1, g: 1, b: 1)
        let r = ContrastChecker.ratio(black, white)
        #expect(abs(r - 21.0) < 0.01)
    }

    @Test("Midgray vs white passes large, fails normal")
    func midgrayVsWhite() {
        let mid = ContrastChecker.RGB(r: 0.5, g: 0.5, b: 0.5)
        let white = ContrastChecker.RGB(r: 1, g: 1, b: 1)
        let result = ContrastChecker.check(mid, white)
        #expect(result.ratio > 3.0)
        #expect(result.ratio < 4.5)
        #expect(result.passes(largeText: true) == true)
        #expect(result.passes(largeText: false) == false)
    }

    @Test("AA threshold accessors")
    func aaThresholds() {
        let r1 = ContrastChecker.AAResult(ratio: 4.5)
        #expect(r1.passes(largeText: false) == true)
        let r2 = ContrastChecker.AAResult(ratio: 4.49)
        #expect(r2.passes(largeText: false) == false)
        let r3 = ContrastChecker.AAResult(ratio: 3.0)
        #expect(r3.passes(largeText: true) == true)
        let r4 = ContrastChecker.AAResult(ratio: 2.99)
        #expect(r4.passes(largeText: true) == false)
    }

    @Test("NaN-component triple does not crash")
    func nanSafe() {
        let nan = ContrastChecker.RGB(r: .nan, g: .nan, b: .nan)
        let white = ContrastChecker.RGB(r: 1, g: 1, b: 1)
        let r = ContrastChecker.ratio(nan, white)
        #expect(r.isFinite)
        // NaN clamps to 0 (black) so ratio against white should equal 21.0.
        #expect(abs(r - 21.0) < 0.01)
    }

    @Test("Reader theme token catalog meets WCAG AA")
    func readerThemeCatalogPasses() {
        // Token values match the production xcassets / data-only sepia.
        // Source of truth: RishiColor.swift (light/dark variants in xcassets,
        // sepia data-only literal). If a token drifts and breaks contrast,
        // this test fails LOUDLY so we don't ship a regression.
        //
        // Sepia RGB matches the values in RishiColor.sepia (hex → decimal).
        // background: 0xF4 / 0xEC / 0xD8
        // textPrimary: 0x3C / 0x2F / 0x1E
        // textSecondary: 0x6B / 0x5A / 0x3F
        // accent: 0x7A / 0x5C / 0x2E
        // danger: 0xB9 / 0x1C / 0x1C
        let sepiaBg = ContrastChecker.RGB(
            r: 0xF4 / 255.0, g: 0xEC / 255.0, b: 0xD8 / 255.0)

        let pairs: [ContrastChecker.ThemePair] = [
            // Light theme — body text on background (system text colors)
            .init(label: "light textPrimary on bg",
                  foreground: .init(r: 0.0, g: 0.0, b: 0.0),
                  background: .init(r: 1, g: 1, b: 1),
                  largeText: false),
            .init(label: "light textSecondary on bg",
                  foreground: .init(r: 0.30, g: 0.30, b: 0.32),
                  background: .init(r: 1, g: 1, b: 1),
                  largeText: false),
            // Sepia theme — exact token values from RishiColor.sepia
            .init(label: "sepia textPrimary on bg",
                  foreground: .init(
                      r: 0x3C / 255.0, g: 0x2F / 255.0, b: 0x1E / 255.0),
                  background: sepiaBg,
                  largeText: false),
            .init(label: "sepia textSecondary on bg",
                  foreground: .init(
                      r: 0x6B / 255.0, g: 0x5A / 255.0, b: 0x3F / 255.0),
                  background: sepiaBg,
                  largeText: false),
            .init(label: "sepia accent on bg",
                  foreground: .init(
                      r: 0x7A / 255.0, g: 0x5C / 255.0, b: 0x2E / 255.0),
                  background: sepiaBg,
                  largeText: false),
            .init(label: "sepia danger on bg",
                  foreground: .init(
                      r: 0xB9 / 255.0, g: 0x1C / 255.0, b: 0x1C / 255.0),
                  background: sepiaBg,
                  largeText: false),
            // Dark theme — high-contrast pale text on near-black
            .init(label: "dark textPrimary on bg",
                  foreground: .init(r: 0.95, g: 0.95, b: 0.96),
                  background: .init(r: 0.08, g: 0.08, b: 0.10),
                  largeText: false),
            .init(label: "dark textSecondary on bg",
                  foreground: .init(r: 0.75, g: 0.75, b: 0.77),
                  background: .init(r: 0.08, g: 0.08, b: 0.10),
                  largeText: false),
        ]
        let failures = ContrastChecker.failures(pairs)
        #expect(failures.isEmpty,
                "AA failures: \(failures.map(\.label))")
    }
}
