//
//  PdfParagraphGrouperTests.swift
//  RishiCoreTests
//
//  Coverage for `PdfParagraphGrouper.paragraphs(from:)` — the pure,
//  PDFKit-free heuristic that groups layout lines (one TextItem per line,
//  in reading order) into paragraph blocks by detecting vertical gaps
//  larger than the page's typical line pitch. `PDFPage.string` has no
//  blank-line boundaries, so PDF read-aloud collapsed a whole page into one
//  chunk; this grouper recovers paragraph structure from line geometry.
//

import Testing
import Foundation
import CoreGraphics
import RishiCore

struct PdfParagraphGrouperTests {

    /// A horizontal line of text at vertical position `y` (PDF user space,
    /// origin bottom-left), fixed height so midY pitch == y pitch.
    private func line(_ text: String, y: CGFloat, x: CGFloat = 50, height: CGFloat = 10) -> TextItem {
        TextItem(
            text: text,
            frame: CGRect(x: x, y: y, width: 200, height: height),
            fontSize: height
        )
    }

    @Test
    func empty_input_returns_empty() {
        #expect(PdfParagraphGrouper.paragraphs(from: []) == [])
    }

    @Test
    func single_line_returns_one_paragraph() {
        #expect(PdfParagraphGrouper.paragraphs(from: [line("Solo line.", y: 100)]) == ["Solo line."])
    }

    @Test
    func uniformly_spaced_lines_stay_one_paragraph() {
        // Even line pitch (20pt) — no gap exceeds the threshold, so the lines
        // belong to one paragraph joined by single spaces.
        let lines = [line("One", y: 100), line("two", y: 80), line("three", y: 60)]
        #expect(PdfParagraphGrouper.paragraphs(from: lines) == ["One two three"])
    }

    @Test
    func large_vertical_gap_starts_new_paragraph() {
        // Lines 1-2 are tight (12pt pitch); a 38pt gap before line 3 marks a
        // paragraph break; lines 3-4 are tight again.
        let lines = [
            line("Para one first", y: 200),
            line("para one second", y: 188),
            line("Para two first", y: 150),
            line("para two second", y: 138),
        ]
        #expect(
            PdfParagraphGrouper.paragraphs(from: lines)
            == ["Para one first para one second", "Para two first para two second"]
        )
    }

    @Test
    func first_line_indent_starts_new_paragraph_without_vertical_gap() {
        // Justified academic layout (e.g. Velleman, "How to Prove It"): a
        // uniform 20pt line pitch throughout, paragraphs marked ONLY by a
        // first-line indent (body margin x=50, indented first lines x=68).
        // A vertical-gap-only heuristic collapses this into one block; indent
        // detection must recover the boundaries.
        let lines = [
            line("Para one first line", y: 200, x: 68),
            line("para one second line", y: 180, x: 50),
            line("para one third line", y: 160, x: 50),
            line("Para two first line", y: 140, x: 68),
            line("para two second line", y: 120, x: 50),
        ]
        #expect(
            PdfParagraphGrouper.paragraphs(from: lines)
            == [
                "Para one first line para one second line para one third line",
                "Para two first line para two second line",
            ]
        )
    }

    @Test
    func leading_flush_line_then_indents_keeps_continuation_separate() {
        // First visible line is a flush-left continuation of a paragraph that
        // began on the previous page; the next indented line starts a fresh
        // paragraph. The continuation must not merge into the indented block.
        let lines = [
            line("continued from prior page", y: 200, x: 50),
            line("New paragraph begins here", y: 180, x: 68),
            line("and continues on this line", y: 160, x: 50),
        ]
        #expect(
            PdfParagraphGrouper.paragraphs(from: lines)
            == [
                "continued from prior page",
                "New paragraph begins here and continues on this line",
            ]
        )
    }

    @Test
    func blank_lines_are_ignored() {
        // Empty / whitespace-only layout lines must not create content or
        // skew the pitch computation.
        let lines = [line("Real one", y: 100), line("   ", y: 80), line("Real two", y: 60)]
        #expect(PdfParagraphGrouper.paragraphs(from: lines) == ["Real one Real two"])
    }
}
