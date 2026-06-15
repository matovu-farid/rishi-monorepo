//
//  PDFReadAloudNextCrossesPageTests.swift
//  rishiTests
//
//  PDF analog of ReaderTTSBridgeNextPrevTests.nextAtEndCrossesChapter /
//  nextAtEndOfBookStops. The EPUB tests prove that pressing Next on the LAST
//  paragraph of a chapter crosses into the next chapter (reusing the same
//  continuation source auto-advance uses) rather than clamping/stopping. PDFs
//  had NO continuation source, so the reported bug was: pressing Next on the
//  last paragraph of a PDF page just stopped at the page boundary.
//
//  These tests drive the real ReaderTTSBridge.next() with a REAL multi-page
//  PDFReaderViewModel wired as the exhaustion source
//  (`vm.paragraphsForFollowingPage()`) — the exact wiring
//  ReadAloudController.startPDF installs — so the page-boundary crossing is
//  exercised end-to-end, not via a stub. The FakeTTSEngine `.holds` script
//  keeps the engine `.playing` so only the explicit next() calls move the play
//  head (no auto-advance race), mirroring the EPUB bridge tests.
//

import Foundation
import Testing
import CoreGraphics
import CoreText
import PDFKit
import RishiAudio
import RishiCore
import RishiReader
import RishiTesting
@testable import rishi

@Suite("PDF read-aloud next() crosses page boundary", .serialized)
@MainActor
struct PDFReadAloudNextCrossesPageTests {

    private static let pageSize = CGSize(width: 612, height: 792)

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let fontSize: CGFloat
    }

    /// Two vertically-separated text blocks -> two paragraphs on one page, so a
    /// page has a real "last paragraph" to press Next on (parity with the EPUB
    /// test's two-paragraph chapter).
    private func twoParagraphPage(_ marker: String) -> [Line] {
        [
            Line(text: "\(marker) first paragraph opens here", x: 72, y: 720, fontSize: 12),
            Line(text: "and runs onto a second tight line.", x: 72, y: 704, fontSize: 12),
            Line(text: "\(marker) second paragraph after a gap", x: 72, y: 540, fontSize: 12),
            Line(text: "also continuing on its own line.", x: 72, y: 524, fontSize: 12),
        ]
    }

    private func makeTempURL(_ name: String) -> URL {
        URL.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    }

    private func writeMultiPageTextPDF(to url: URL, pages: [[Line]]) throws {
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
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

    private func loadedVM(url: URL) async -> PDFReaderViewModel {
        let vm = PDFReaderViewModel(
            book: Book(userId: UUID(), title: "Continuation Fixture", formatType: .pdf, fileURL: "Books/x/cont.pdf"),
            userId: UUID(),
            documentURL: url,
            positionStore: InMemoryPositionStore(),
            debounceSeconds: 5.0
        )
        await vm.load()
        return vm
    }

    /// Parity with auto-advance: pressing Next on the LAST paragraph of a PDF
    /// page must cross into the next page (its index resets to "0"), reusing the
    /// same continuation source auto-advance uses, not clamp at the page's last
    /// paragraph. Reproduces the reported bug where the forward button refused
    /// to cross the PDF page boundary.
    @Test("next() at the last paragraph of a page crosses into the next page")
    func nextAtEndCrossesPage() async throws {
        let url = makeTempURL("bridge-cross")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [twoParagraphPage("Alpha"), twoParagraphPage("Beta")])

        let vm = await loadedVM(url: url)
        let doc = try #require(vm.document)
        let firstPage = vm.paragraphsForReadAloud(document: doc, currentPageIndex: 0)
        try #require(firstPage.count == 2, "page 0 must have two paragraphs to press Next on the last one; got \(firstPage)")

        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onExhausted: { await vm.paragraphsForFollowingPage() }
        )
        await env.bridge.start(paragraphs: firstPage)
        await waitUntil(timeout: 2) { startedPassageIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startedPassageIds(env.engine).last == "1" }

        // At the last paragraph of page 0: cross into page 1 (its index resets to
        // "0"), rather than clamping at "1".
        await env.bridge.next()
        await waitUntil(timeout: 3) { startedPassageIds(env.engine) == ["0", "1", "0"] }

        await env.bridge.stop()
        #expect(startedPassageIds(env.engine) == ["0", "1", "0"],
                "Next at the page boundary must continue into the next page, not stop")
        #expect(vm.pageIndex == 1, "the live page must follow narration onto page 1, was \(vm.pageIndex)")
    }

    /// At the last paragraph of the LAST page (continuation source dry), Next
    /// must not fabricate an out-of-range passage; it stops cleanly. Mirrors
    /// nextAtEndOfBookStops.
    @Test("next() at the last paragraph of the last page does not start out-of-range")
    func nextAtEndOfDocumentStops() async throws {
        let url = makeTempURL("bridge-end")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [twoParagraphPage("Alpha")]) // single page

        let vm = await loadedVM(url: url)
        let doc = try #require(vm.document)
        let onlyPage = vm.paragraphsForReadAloud(document: doc, currentPageIndex: 0)
        try #require(onlyPage.count == 2, "the only page must have two paragraphs; got \(onlyPage)")

        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .holds) },
            onExhausted: { await vm.paragraphsForFollowingPage() }
        )
        await env.bridge.start(paragraphs: onlyPage)
        await waitUntil(timeout: 2) { startedPassageIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startedPassageIds(env.engine).last == "1" }

        await env.bridge.next()
        // Give the exhaustion path time to query the (empty) following page.
        await waitUntil(timeout: 2) { false }

        await env.bridge.stop()
        #expect(startedPassageIds(env.engine) == ["0", "1"],
                "must not start an out-of-range passage at end of document")
    }
}
