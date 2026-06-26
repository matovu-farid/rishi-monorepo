



















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

        
        
        await env.bridge.next()
        await waitUntil(timeout: 3) { startedPassageIds(env.engine) == ["0", "1", "0"] }

        await env.bridge.stop()
        #expect(startedPassageIds(env.engine) == ["0", "1", "0"],
                "Next at the page boundary must continue into the next page, not stop")
        #expect(vm.pageIndex == 1, "the live page must follow narration onto page 1, was \(vm.pageIndex)")
    }

    
    
    
    @Test("next() at the last paragraph of the last page does not start out-of-range")
    func nextAtEndOfDocumentStops() async throws {
        let url = makeTempURL("bridge-end")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeMultiPageTextPDF(to: url, pages: [twoParagraphPage("Alpha")]) 

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
        
        await waitUntil(timeout: 2) { false }

        await env.bridge.stop()
        #expect(startedPassageIds(env.engine) == ["0", "1"],
                "must not start an out-of-range passage at end of document")
    }
}
