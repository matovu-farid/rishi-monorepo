//
//  PositionSyncBindingSignpostTests.swift
//  rishiTests
//
//  Phase 19 Plan 19-06 — F-P0-07 + F-P1-02 instrumentation.
//
//  Locked decision #4 keeps the 250ms poll for v1; this plan adds OSSignposter
//  markers around each poll tick so Instruments can attribute the wake rate
//  during cold-launch / reader-running captures. The push-based AsyncStream
//  variant is documented as v1.1 backlog inside the binding source.
//
//  OSSignposter has no public read-side introspection API, so runtime
//  "signpost-fires" assertions are not possible. The actionable contract is
//  that each binding source file:
//    1. imports os.signpost,
//    2. declares the shared positionSyncSignposter (subsystem org.fidexa.rishi,
//       category position-sync),
//    3. calls beginInterval / endInterval with the named tick event inside the
//       poll loop, and
//    4. carries the single-line "v1.1 backlog" comment pointing at the ADR.
//
//  This test suite enforces those invariants via source-text reads — if a
//  future refactor strips the signposter or the backlog pointer, the test
//  goes red.
//
//  Swift Testing only.
//

import Testing
import Foundation

@Suite("PositionSyncBinding signpost instrumentation")
struct PositionSyncBindingSignpostTests {

    // MARK: - File locations

    /// Locate the binding source files relative to the test bundle. Tests run
    /// from DerivedData, so we walk up from #filePath (the test file itself)
    /// to find the sibling Reader/ directory.
    private static func bindingSource(_ name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let rishiTestsDir = testFile.deletingLastPathComponent()
        let projectDir = rishiTestsDir.deletingLastPathComponent()
        let readerDir = projectDir.appendingPathComponent("rishi/Reader", isDirectory: true)
        let fileURL = readerDir.appendingPathComponent(name)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - EPUB binding

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

    // MARK: - PDF binding

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

    // MARK: - Backlog pointer

    @Test("Both binding files carry the v1.1 backlog comment pointing at the ADR")
    func test_filesContainBacklogPointer() throws {
        let epubSource = try Self.bindingSource("EPUBReaderPositionSyncBinding.swift")
        let pdfSource = try Self.bindingSource("PDFReaderPositionSyncBinding.swift")
        #expect(epubSource.contains("v1.1 backlog"))
        #expect(epubSource.contains("SWIFT-CONCURRENCY-RULES.md"))
        #expect(pdfSource.contains("v1.1 backlog"))
        #expect(pdfSource.contains("SWIFT-CONCURRENCY-RULES.md"))
    }

    // MARK: - 250ms cadence preservation (locked decision #4)

    @Test("Both binding files preserve the 250ms poll cadence (v1 behavior)")
    func test_pollCadencePreserved() throws {
        let epubSource = try Self.bindingSource("EPUBReaderPositionSyncBinding.swift")
        let pdfSource = try Self.bindingSource("PDFReaderPositionSyncBinding.swift")
        #expect(epubSource.contains("250_000_000"))
        #expect(pdfSource.contains("250_000_000"))
    }
}
