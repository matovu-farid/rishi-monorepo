//
//  FooterTokens.swift
//  RishiCore (Phase 27 plan 27-02)
//
//  Direct port of electron `apps/rishi-electron/src/renderer/src/components/
//  pdf/utils/buildFooterMask.ts:63-76`. Pure-Foundation helper used by the
//  Apple PDF footer detection strategies (27-03 / 27-04) to collapse trivial
//  variants ("Page 47" vs "Page 48", "47 of 350" vs "48 of 350", "vii" vs
//  "42") onto the same repetition key so the suffix matcher can recognise
//  them as the same recurring footer regardless of changing page number.
//
//  Zero PDFKit / layout dependency — strategies that need it depend
//  directly on RishiCore.
//

import Foundation

/// Footer-token normalisation utilities.
///
/// `FooterTokens.normalize(_:)` is a verbatim port of electron's
/// `normalizeFooterToken(s)`. Pure-numeric or pure-roman-numeral strings
/// become the `__NUM__` sentinel; mixed text has standalone digit runs
/// (word-boundary anchored) replaced with the same sentinel.
public enum FooterTokens {

    /// The replacement token for pure or embedded digit runs. Matches the
    /// electron sentinel verbatim so cross-platform hash keys are identical.
    public static let sentinel = "__NUM__"

    /// `^[ivxlcdm\d]+$`, case-insensitive. Matches pure-numeric or
    /// pure-roman-numeral strings AFTER lowercasing + whitespace collapse.
    /// `NSRegularExpression` instances are documented thread-safe for read
    /// access, so the `nonisolated(unsafe)` static is sound under Swift 6
    /// strict concurrency.
    nonisolated(unsafe) private static let pureNumericRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "^[ivxlcdm0-9]+$",
            options: [.caseInsensitive]
        )
    }()

    /// `\b\d+\b`. Replaces embedded ASCII digit runs with the sentinel.
    /// ASCII-only by design — electron's JS `\d` is also `[0-9]`-only by
    /// default; do not add Unicode flags.
    nonisolated(unsafe) private static let embeddedNumberRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "\\b\\d+\\b",
            options: []
        )
    }()

    /// Collapse trivial footer variants to a comparable key.
    ///
    /// Steps (mirroring electron):
    /// 1. Trim leading/trailing whitespace.
    /// 2. Collapse interior whitespace runs to a single space.
    /// 3. Lowercase (locale-independent).
    /// 4. If the whole string matches `^[ivxlcdm\d]+$`, return `__NUM__`.
    /// 5. Otherwise replace every `\b\d+\b` run with `__NUM__`.
    ///
    /// - Parameter raw: The raw footer/header text token.
    /// - Returns: The normalised key suitable for repetition counting.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .lowercased()
        let range = NSRange(collapsed.startIndex..., in: collapsed)
        if pureNumericRegex.firstMatch(in: collapsed, range: range) != nil {
            return sentinel
        }
        return embeddedNumberRegex.stringByReplacingMatches(
            in: collapsed,
            range: range,
            withTemplate: sentinel
        )
    }
}
