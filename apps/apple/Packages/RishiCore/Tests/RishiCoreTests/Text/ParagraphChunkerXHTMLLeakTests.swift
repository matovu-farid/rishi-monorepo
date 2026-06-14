//
//  ParagraphChunkerXHTMLLeakTests.swift
//  RishiCoreTests (Phase 29 plan 29-02)
//
//  Locks the in-progress ParagraphChunker XHTML-strip fix (RESEARCH 3.1) behind
//  a real-document test: a full Readium-style XHTML document (xml prolog, head
//  with title/style/@font-face/script, body with heading + prose paragraphs)
//  must chunk to leak-free prose. Before the fix, `<head>`/`<style>`/`<script>`
//  character data and raw scaffold tags leaked straight into the TTS chunks
//  (reader-tts-xml-and-loading symptom 1) because the chunker only entered the
//  tag-aware path when the text contained `<p`.
//
//  Invariant asserted: no chunk contains markup `<`, no chunk contains CSS `{`
//  or `@font-face`, no chunk carries the `<title>` or `<script>` scaffold text,
//  count >= 2, and at least one chunk is real prose.
//

import Testing
import Foundation
import RishiCore

@Suite("ParagraphChunker XHTML leak guard")
struct ParagraphChunkerXHTMLLeakTests {

    /// A representative Readium-style XHTML document: xml prolog, a head with a
    /// title, an inline stylesheet (including an `@font-face` rule), and a
    /// script, followed by a body with a heading and two prose paragraphs.
    private let xhtml = """
    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head>
      <title>Chapter One Scaffold</title>
      <style>
        p { font-family: serif; line-height: 1.4; }
        @font-face { font-family: "Bookerly"; src: url(fonts/bookerly.otf); }
      </style>
      <script>var pageScaffoldMarker = 1;</script>
    </head>
    <body>
      <h1>Chapter One</h1>
      <p>Alice was beginning to get very tired of sitting by her sister on the bank.</p>
      <p>So she was considering in her own mind whether the pleasure of making a daisy chain would be worth the trouble.</p>
    </body>
    </html>
    """

    @Test("full XHTML document chunks to prose with no scaffold leak")
    func full_xhtml_document_chunks_to_clean_prose() {
        let chunks = ParagraphChunker.chunk(xhtml)

        // At least the two body paragraphs survive as distinct prose chunks.
        #expect(chunks.count >= 2)

        // No markup `<` leaks into any chunk.
        #expect(chunks.allSatisfy { !$0.contains("<") })

        // No CSS leaks: neither the `{` of a rule block nor the `@font-face`
        // at-rule keyword may appear in any chunk.
        #expect(chunks.allSatisfy { !$0.contains("{") })
        #expect(chunks.allSatisfy { !$0.contains("@font-face") })

        // No `<head>` scaffold character data leaks: the `<title>` text and the
        // `<script>` body must be stripped wholesale, not just tag-stripped.
        #expect(chunks.allSatisfy { !$0.contains("Scaffold") })
        #expect(chunks.allSatisfy { !$0.contains("pageScaffoldMarker") })

        // The CSS `src: url(...)` value must not survive either.
        #expect(chunks.allSatisfy { !$0.contains("bookerly") })

        // At least one chunk is real prose from the body.
        #expect(chunks.contains { $0.contains("Alice was beginning") })
    }
}
