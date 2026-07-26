import Foundation

/// WCAG 2.1 contrast-ratio calculator. Pure Swift — no SwiftUI / UIColor /
/// NSColor — so it runs in `swift test` on a macOS host without UIKit.
///
/// Reference: https://www.w3.org/TR/WCAG21/#contrast-minimum
///
/// AA thresholds (normal text >= 4.5:1, large text >= 3.0:1) are encoded on
/// `AAResult.passes(largeText:)`. The token-pair audit surface
/// (`audit(_:)` / `failures(_:)`) lets test suites assert every
/// (foreground, background) combo we actually ship in the reader chrome.
enum ContrastChecker {

    /// Component-wise sRGB triple in [0, 1].
    public struct RGB: Equatable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r; self.g = g; self.b = b
        }
    }

    public struct AAResult: Equatable, Sendable {
        public let ratio: Double
        public init(ratio: Double) { self.ratio = ratio }
        public func passes(largeText: Bool) -> Bool {
            ratio >= (largeText ? 3.0 : 4.5)
        }
    }

    /// Relative luminance per WCAG 2.1 formula.
    ///
    /// NaN / non-finite components clamp to 0 so the math never produces
    /// non-finite output — important for the audit fixture, which we want
    /// to fail loudly rather than crash when a token is misconfigured.
    public static func luminance(_ c: RGB) -> Double {
        func ch(_ x: Double) -> Double {
            guard x.isFinite else { return 0 }
            let clamped = max(0, min(1, x))
            return clamped <= 0.03928
                ? clamped / 12.92
                : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }

    /// Contrast ratio between two sRGB colors.
    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    public static func check(_ a: RGB, _ b: RGB) -> AAResult {
        AAResult(ratio: ratio(a, b))
    }

    // MARK: - Token audit
    //
    // Each (foreground, background) pair we ship in production reader chrome.
    // Test fixture lives in the test target — we DO NOT pull SwiftUI Color
    // into this file because Color components are private on macOS.

    public struct ThemePair: Equatable, Sendable {
        public let label: String
        public let foreground: RGB
        public let background: RGB
        public let largeText: Bool
        public init(label: String, foreground: RGB, background: RGB, largeText: Bool) {
            self.label = label
            self.foreground = foreground
            self.background = background
            self.largeText = largeText
        }
    }

    public static func audit(_ pairs: [ThemePair]) -> [(pair: ThemePair, result: AAResult)] {
        pairs.map { ($0, check($0.foreground, $0.background)) }
    }

    public static func failures(_ pairs: [ThemePair]) -> [ThemePair] {
        audit(pairs).compactMap { $0.result.passes(largeText: $0.pair.largeText) ? nil : $0.pair }
    }
}
