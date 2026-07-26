@testable import rishi
//
//  HTMLTextCleanerTests.swift
//  RishiCoreTests
//
//  Focused coverage for the HTML/XHTML cleanup helpers extracted out of
//  ParagraphChunker in plan 34-12. The end-to-end markup paths are still
//  covered by ParagraphChunkerTests / ParagraphChunkerXHTMLLeakTests; these
//  assert the individual cleanup steps directly.
//

import Testing


@Suite("HTMLTextCleaner")
struct HTMLTextCleanerTests {

    // Mirror the chunker's own blank-line splitter behaviour closely enough for
    // the cleaner's region handling: split on runs of >= 2 newlines.
    private static func blankLineSplit(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    @Test("stripTags removes inline markup and decodes common entities")
    func stripTagsDecodes() {
        let html = "<em>Hello</em> &amp; <a href=\"x\">world</a> done&#39;s"
        #expect(HTMLTextCleaner.stripTags(html) == "Hello & world done's")
    }

    @Test("stripTags collapses internal whitespace and trims")
    func stripTagsCollapses() {
        #expect(HTMLTextCleaner.stripTags("  <b>  a   b  </b>  ") == "a b")
    }

    @Test("removeNonSpokenElements drops head/style/script bodies")
    func removeNonSpoken() {
        let html = "<head><title>T</title></head><style>.a{}</style><script>x()</script><p>Body</p>"
        let out = HTMLTextCleaner.removeNonSpokenElements(html)
        #expect(!out.contains("title"))
        #expect(!out.contains(".a{}"))
        #expect(!out.contains("x()"))
        #expect(out.contains("<p>Body</p>"))
    }

    @Test("insertBlockBoundaries wraps block tags with blank lines")
    func insertBoundaries() {
        let out = HTMLTextCleaner.insertBlockBoundaries("<h1>Title</h1><p>Body</p>")
        // Each block tag gets \n\n on both sides so splitters break on them.
        #expect(out.contains("\n\n<h1>"))
        #expect(out.contains("</h1>\n\n"))
        #expect(out.contains("\n\n<p>"))
    }

    @Test("splitByPTags extracts <p> bodies and strips them")
    func splitPTags() {
        let html = "<p>First para.</p><p>Second <em>para</em>.</p>"
        let out = HTMLTextCleaner.splitByPTags(html, blankLineSplit: Self.blankLineSplit)
        #expect(out == ["First para.", "Second para ."])
    }

    @Test("splitOutsideRegion strips scaffold tags before blank-line split")
    func splitOutside() {
        let region = "<h1>Heading</h1>\n\n<div>Body</div>"
        let out = HTMLTextCleaner.splitOutsideRegion(region, blankLineSplit: Self.blankLineSplit)
        #expect(out == ["Heading", "Body"])
    }

    @Test("prepare composes removeNonSpoken then insertBlockBoundaries")
    func prepareComposition() {
        let html = "<style>.a{}</style><p>Body</p>"
        let out = HTMLTextCleaner.prepare(html)
        #expect(!out.contains(".a{}"))
        #expect(out.contains("\n\n<p>"))
    }
}
