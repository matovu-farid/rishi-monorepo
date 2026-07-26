@testable import rishi
//
//  PDFReadAloudPageContinuationTests.swift
//  RishiReaderTests
//
//  Coverage for PDF read-aloud page-boundary continuation. Mirrors the EPUB
//  chapter-continuation tests (EPUBReadAloudChapterContinuationTests): proves
//  `paragraphsForFollowingPage()` advances narration across a page boundary,
//  skips pages with no selectable text, moves the live `pageIndex` so the
//  visible page follows, and returns `[]` at the end of the document (which
//  the read-aloud bridge treats as "stop").
//
//  Builds synthetic multi-page PDFs with a CoreGraphics PDF context (real
//  selectable text), mirroring PDFReadAloudParagraphsTests.
//

import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit




@Suite("PDFReadAloudPageContinuation", .serialized)
struct PDFReadAloudPageContinuationTests {

    private static let pageSize = CGSize(width: 612, height: 792)

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let fontSize: CGFloat
    }

    /// One tight two-line paragraph anchored near the top of a page.
    private func bodyLines(_ marker: String) -> [Line] {
        [
            Line(text: "\(marker) paragraph opens the page here", x: 72, y: 720, fontSize: 12),
            Line(text: "and continues on a second tight line.", x: 72, y: 704, fontSize: 12),
        ]
    }

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    }

    /// Writes a multi-page PDF. An empty `[Line]` array produces a page with
    /// no drawn text (no selectable characters) to exercise empty-page skip.
    private func writeMultiPageTextPDF(to url: URL, pages: [[Line]]) throws {
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create CGContext for PDF")
            return
        }
        for page in pages {
            ctx.beginPDFPage(nil)
            for line in page {
                let font = CTFontCreateWithName("Helvetica" as CFString, line.fontSize, nil)
                let attributed = NSAttributedString(
                    string: line.text,
                    attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
                )
                let ctLine = CTLineCreateWithAttributedString(attributed)
                ctx.textPosition = CGPoint(x: line.x, y: line.y)
                CTLineDraw(ctLine, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func makeViewModel(documentURL: URL) async -> PDFReaderViewModel {
        let vm = PDFReaderViewModel(
            book: Book(userId: UUID(), title: "Continuation Fixture", formatType: .pdf, fileURL: "Books/x/cont.pdf"),
            userId: UUID(),
            documentURL: documentURL,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 0.05
        )
        await vm.load()
        return vm
    }

    @Test("Following page returns the next page's paragraphs and turns the page")
    func crossesIntoNextPage() async throws {
        let url = makeTempURL("cont-two")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])

        let vm = await makeViewModel(documentURL: url)
        let doc = try #require(vm.document)
        // Ground truth for the next page's paragraphs, captured independently
        // (completeness, mirroring the EPUB assertContinuesIntoNextChapter).
        let expectedNext = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: 1)))
        try #require(!expectedNext.isEmpty)
        vm.seek(toPage: 0)

        let next = await vm.paragraphsForFollowingPage()

        #expect(!next.isEmpty, "expected the following page's paragraphs, got none")
        #expect(next == expectedNext,
                "following page must be page 1's complete paragraph list; got \(next)")
        #expect(vm.pageIndex == 1, "live page should follow narration to page 1, was \(vm.pageIndex)")
    }

    @Test("Following page skips pages with no selectable text")
    func skipsEmptyPages() async throws {
        let url = makeTempURL("cont-skip")
        defer { try? FileManager.default.removeItem(at: url) }
        // page 0 text, page 1 empty (no glyphs), page 2 text.
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), [], bodyLines("Gamma")])

        let vm = await makeViewModel(documentURL: url)
        vm.seek(toPage: 0)

        let next = await vm.paragraphsForFollowingPage()

        #expect(next.joined(separator: " ").contains("Gamma"), "should skip the blank page and reach page 2, got \(next)")
        #expect(vm.pageIndex == 2, "live page should land on page 2, was \(vm.pageIndex)")
    }

    @Test("Following page returns [] at the end of the document")
    func stopsAtEndOfDocument() async throws {
        let url = makeTempURL("cont-end")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])

        let vm = await makeViewModel(documentURL: url)
        vm.seek(toPage: 1) // last page

        let next = await vm.paragraphsForFollowingPage()

        #expect(next.isEmpty, "past the last page narration should stop, got \(next)")
        #expect(vm.pageIndex == 1, "page index should not move past the last page, was \(vm.pageIndex)")
    }

    // MARK: - Backward continuation (Previous at the first paragraph of a page)

    @Test("Preceding page returns the previous page's paragraphs and turns the page back")
    func crossesIntoPreviousPage() async throws {
        let url = makeTempURL("prev-two")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])

        let vm = await makeViewModel(documentURL: url)
        let doc = try #require(vm.document)
        let expectedPrev = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: 0)))
        try #require(!expectedPrev.isEmpty)
        vm.seek(toPage: 1)

        let prev = await vm.paragraphsForPrecedingPage()

        #expect(!prev.isEmpty, "expected the preceding page's paragraphs, got none")
        #expect(prev == expectedPrev,
                "preceding page must be page 0's complete paragraph list; got \(prev)")
        #expect(vm.pageIndex == 0, "live page should follow narration back to page 0, was \(vm.pageIndex)")
    }

    @Test("Preceding page skips pages with no selectable text")
    func skipsEmptyPagesBackward() async throws {
        let url = makeTempURL("prev-skip")
        defer { try? FileManager.default.removeItem(at: url) }
        // page 0 text, page 1 empty (no glyphs), page 2 text.
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), [], bodyLines("Gamma")])

        let vm = await makeViewModel(documentURL: url)
        vm.seek(toPage: 2)

        let prev = await vm.paragraphsForPrecedingPage()

        #expect(prev.joined(separator: " ").contains("Alpha"), "should skip the blank page and reach page 0, got \(prev)")
        #expect(vm.pageIndex == 0, "live page should land on page 0, was \(vm.pageIndex)")
    }

    @Test("Preceding page returns [] at the start of the document")
    func stopsAtStartOfDocument() async throws {
        let url = makeTempURL("prev-start")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [bodyLines("Alpha"), bodyLines("Beta")])

        let vm = await makeViewModel(documentURL: url)
        vm.seek(toPage: 0) // first page

        let prev = await vm.paragraphsForPrecedingPage()

        #expect(prev.isEmpty, "before the first page narration should stay put, got \(prev)")
        #expect(vm.pageIndex == 0, "page index should not move before the first page, was \(vm.pageIndex)")
    }

    // MARK: - Real-fixture coverage (how-to-prove-it.pdf)
    //
    // Synthetic CGContext PDFs above pin the edge cases (empty-page skip,
    // end-of-document). These exercise a REAL multi-page book with
    // indent-delimited paragraphs and front matter — the layout that broke
    // page-level extraction before — mirroring the EPUB continuation tests'
    // use of real `rationality.epub` / `alice.epub` fixtures. We must not rely
    // on the trivial seeded sample.pdf alone.

    /// Page indices whose layout-aware extraction yields >= 1 paragraph (skips
    /// front matter / blank / image-only pages). Mirrors the EPUB test's
    /// `nonEmptyContentIndices`.
    private func contentPageIndices(doc: PDFDocument) -> [Int] {
        (0..<doc.pageCount).filter { i in
            guard let page = doc.page(at: i) else { return false }
            return !PDFReadAloudParagraphs.paragraphs(from: page).isEmpty
        }
    }

    private func howToProveItURL() throws -> URL {
        try #require(PackageTestResourceBundle.bundle.url(forResource: "how-to-prove-it", withExtension: "pdf"))
    }

    @Test("how-to-prove-it: every content-page boundary continues into the next content page")
    func realPDFCrossesEveryContentBoundary() async throws {
        let url = try howToProveItURL()
        let vm = await makeViewModel(documentURL: url)
        let doc = try #require(vm.document)
        let content = contentPageIndices(doc: doc)
        try #require(content.count >= 2, "fixture must have >= 2 content pages to cross a boundary")

        // From each content page, the following page must be the NEXT content
        // page's COMPLETE paragraph list (skipping any blank/front-matter pages
        // between them), and the live page must follow there. Reuse one VM and
        // re-anchor the cursor via seek() before each call.
        for (k, pageA) in content.dropLast().enumerated() {
            let pageB = content[k + 1]
            let expectedNext = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: pageB)))

            vm.seek(toPage: pageA)
            let following = await vm.paragraphsForFollowingPage()

            #expect(!following.isEmpty,
                    "from content page \(pageA), read-aloud must continue (got nothing)")
            #expect(following == expectedNext,
                    "from page \(pageA) the following batch must be page \(pageB)'s complete paragraph list")
            #expect(vm.pageIndex == pageB,
                    "live page must follow narration to \(pageB), was \(vm.pageIndex)")
        }
    }

    @Test("how-to-prove-it: following page returns [] at the last content page")
    func realPDFStopsAtLastContentPage() async throws {
        let url = try howToProveItURL()
        let vm = await makeViewModel(documentURL: url)
        let doc = try #require(vm.document)
        let content = contentPageIndices(doc: doc)
        let last = try #require(content.last)

        vm.seek(toPage: last)
        let following = await vm.paragraphsForFollowingPage()

        #expect(following.isEmpty,
                "no content page follows the last one — must return [] so playback stops")
    }

    @Test("how-to-prove-it: every content-page boundary continues into the previous content page")
    func realPDFCrossesEveryContentBoundaryBackward() async throws {
        let url = try howToProveItURL()
        let vm = await makeViewModel(documentURL: url)
        let doc = try #require(vm.document)
        let content = contentPageIndices(doc: doc)
        try #require(content.count >= 2, "fixture must have >= 2 content pages to cross a boundary")

        // From each content page (except the first), the preceding page must be
        // the PREVIOUS content page's COMPLETE paragraph list (skipping any
        // blank/front-matter pages between them), and the live page must follow
        // back there. Reuse one VM and re-anchor the cursor via seek() each call.
        for (k, pageB) in content.dropFirst().enumerated() {
            let pageA = content[k] // the content page before pageB
            let expectedPrev = PDFReadAloudParagraphs.paragraphs(from: try #require(doc.page(at: pageA)))

            vm.seek(toPage: pageB)
            let preceding = await vm.paragraphsForPrecedingPage()

            #expect(!preceding.isEmpty,
                    "from content page \(pageB), read-aloud must continue back (got nothing)")
            #expect(preceding == expectedPrev,
                    "from page \(pageB) the preceding batch must be page \(pageA)'s complete paragraph list")
            #expect(vm.pageIndex == pageA,
                    "live page must follow narration back to \(pageA), was \(vm.pageIndex)")
        }
    }

    @Test("how-to-prove-it: preceding page returns [] at the first content page")
    func realPDFStopsAtFirstContentPage() async throws {
        let url = try howToProveItURL()
        let vm = await makeViewModel(documentURL: url)
        let doc = try #require(vm.document)
        let content = contentPageIndices(doc: doc)
        let first = try #require(content.first)

        vm.seek(toPage: first)
        let preceding = await vm.paragraphsForPrecedingPage()

        #expect(preceding.isEmpty,
                "no content page precedes the first one — must return [] so playback stays put")
    }
}
