//
//  FooterTokensTests.swift
//  RishiCoreTests (Phase 27 plan 27-02)
//
//  Swift Testing parity coverage for `FooterTokens.normalize(_:)` — direct
//  port of electron `apps/rishi-electron/src/renderer/src/components/pdf/
//  utils/buildFooterMask.ts:63-76`. Mirrors the electron parity table from
//  27-02-PLAN.md so any drift in regex semantics surfaces immediately.
//

import Testing
import Foundation
import RishiCore

struct FooterTokensTests {

    // MARK: - Pure numeric / roman

    @Test
    func pure_arabic_number_becomes_sentinel() {
        #expect(FooterTokens.normalize("42") == "__NUM__")
    }

    @Test
    func pure_lowercase_roman_becomes_sentinel() {
        #expect(FooterTokens.normalize("vii") == "__NUM__")
    }

    @Test
    func pure_uppercase_roman_becomes_sentinel() {
        // Lowercased first; regex is case-insensitive but the lowercased
        // pipeline means uppercase input still matches.
        #expect(FooterTokens.normalize("VII") == "__NUM__")
    }

    @Test
    func pure_roman_ix_becomes_sentinel() {
        #expect(FooterTokens.normalize("ix") == "__NUM__")
    }

    // MARK: - Embedded digits

    @Test
    func page_47_collapses_embedded_digit_run() {
        #expect(FooterTokens.normalize("Page 47") == "page __NUM__")
    }

    @Test
    func page_47_and_48_normalize_identically() {
        #expect(FooterTokens.normalize("Page 47") == FooterTokens.normalize("Page 48"))
    }

    @Test
    func multi_digit_run_in_mixed_string() {
        #expect(FooterTokens.normalize("47 of 350") == "__NUM__ of __NUM__")
    }

    @Test
    func chapter_three_collapses_embedded() {
        #expect(FooterTokens.normalize("Chapter 3") == "chapter __NUM__")
    }

    @Test
    func three_point_one_four_collapses_around_dot() {
        // `.` is a non-word char so \b\d+\b matches both "3" and "14".
        #expect(FooterTokens.normalize("3.14") == "__NUM__.__NUM__")
    }

    // MARK: - Whitespace + casing

    @Test
    func interior_whitespace_collapses_and_lowercases() {
        #expect(FooterTokens.normalize("  hello  world  ") == "hello world")
    }

    // MARK: - No-op cases

    @Test
    func plain_text_with_no_digits_only_lowercases() {
        #expect(FooterTokens.normalize("the end.") == "the end.")
    }

    @Test
    func empty_input_stays_empty() {
        #expect(FooterTokens.normalize("") == "")
    }

    // MARK: - Equivalence intent

    @Test
    func pure_roman_and_pure_arabic_collapse_to_same_sentinel() {
        // The suffix-matcher in 27-03/27-04 relies on this: any pure
        // page-number-shaped token (Arabic OR Roman) hashes identically.
        #expect(FooterTokens.normalize("vii") == FooterTokens.normalize("42"))
    }

    @Test
    func different_shapes_do_not_collapse_together() {
        // No over-collapse: a plain "the end." line must NOT hash the same
        // as "Page 47" — that would tag chapter-end lines as footers.
        #expect(FooterTokens.normalize("the end.") != FooterTokens.normalize("Page 47"))
    }
}
