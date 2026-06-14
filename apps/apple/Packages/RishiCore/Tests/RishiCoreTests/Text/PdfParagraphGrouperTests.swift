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
    private func line(_ text: String, y: CGFloat, height: CGFloat = 10) -> TextItem {
        TextItem(
            text: text,
            frame: CGRect(x: 50, y: y, width: 200, height: height),
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
    func blank_lines_are_ignored() {
        // Empty / whitespace-only layout lines must not create content or
        // skew the pitch computation.
        let lines = [line("Real one", y: 100), line("   ", y: 80), line("Real two", y: 60)]
        #expect(PdfParagraphGrouper.paragraphs(from: lines) == ["Real one Real two"])
    }
}
