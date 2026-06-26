//


//

//






import Testing
import Foundation

@Suite("PositionSyncBinding signpost instrumentation")
struct PositionSyncBindingSignpostTests {

    

    private static func bindingSource(_ name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let rishiTestsDir = testFile.deletingLastPathComponent()
        let projectDir = rishiTestsDir.deletingLastPathComponent()
        let readerDir = projectDir.appendingPathComponent("rishi/Reader", isDirectory: true)
        let fileURL = readerDir.appendingPathComponent(name)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    

    @Test("EPUB binding imports os.signpost + declares positionSyncSignposter")
    func test_epubBindingDeclaresSignposter() throws {
        let source = try Self.bindingSource("EPUBReaderPositionSyncBinding.swift")
        #expect(source.contains("import os.signpost"))
        #expect(source.contains("OSSignposter("))
        #expect(source.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(source.contains("category: \"position-sync\""))
    }

    @Test("EPUB binding wraps poll body with begin/endInterval for epub.position.poll.tick")
    func test_epubBindingEmitsSignpost() throws {
        let source = try Self.bindingSource("EPUBReaderPositionSyncBinding.swift")
        #expect(source.contains("epub.position.poll.tick"))
        #expect(source.contains("beginInterval"))
        #expect(source.contains("endInterval"))
    }

    

    @Test("PDF binding imports os.signpost + declares positionSyncSignposter")
    func test_pdfBindingDeclaresSignposter() throws {
        let source = try Self.bindingSource("PDFReaderPositionSyncBinding.swift")
        #expect(source.contains("import os.signpost"))
        #expect(source.contains("OSSignposter("))
        #expect(source.contains("subsystem: \"org.fidexa.rishi\""))
        #expect(source.contains("category: \"position-sync\""))
    }

    @Test("PDF binding wraps poll body with begin/endInterval for pdf.position.poll.tick")
    func test_pdfBindingEmitsSignpost() throws {
        let source = try Self.bindingSource("PDFReaderPositionSyncBinding.swift")
        #expect(source.contains("pdf.position.poll.tick"))
        #expect(source.contains("beginInterval"))
        #expect(source.contains("endInterval"))
    }

    

    @Test("Both binding files carry the v1.1 backlog comment pointing at the ADR")
    func test_filesContainBacklogPointer() throws {
        let epubSource = try Self.bindingSource("EPUBReaderPositionSyncBinding.swift")
        let pdfSource = try Self.bindingSource("PDFReaderPositionSyncBinding.swift")
        #expect(epubSource.contains("v1.1 backlog"))
        #expect(epubSource.contains("SWIFT-CONCURRENCY-RULES.md"))
        #expect(pdfSource.contains("v1.1 backlog"))
        #expect(pdfSource.contains("SWIFT-CONCURRENCY-RULES.md"))
    }

    

    @Test("Both binding files preserve the 250ms poll cadence (v1 behavior)")
    func test_pollCadencePreserved() throws {
        let epubSource = try Self.bindingSource("EPUBReaderPositionSyncBinding.swift")
        let pdfSource = try Self.bindingSource("PDFReaderPositionSyncBinding.swift")
        #expect(epubSource.contains("250_000_000"))
        #expect(pdfSource.contains("250_000_000"))
    }
}
