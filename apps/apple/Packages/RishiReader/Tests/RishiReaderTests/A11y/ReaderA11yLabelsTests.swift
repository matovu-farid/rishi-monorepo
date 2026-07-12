import Foundation
import Testing

/// File-level invariants for reader chrome accessibility.
///
/// We assert the source files themselves contain the expected modifiers,
/// rather than spinning up SwiftUI / ViewInspector. The reasoning:
///   1. `swift test` on a macOS host can't render SwiftUI views with
///      `@Environment(\.accessibility…)` reliably without a real window.
///   2. The grep-style invariants catch *regressions* (someone re-adds
///      a fixed font size or a raw `.animation(`) — which is the whole
///      point of A11Y-02 / A11Y-03 enforcement.
@Suite("Reader a11y — file-level invariants")
struct ReaderA11yLabelsTests {

    /// Resolve the reader's `Sources/.../UI` directory relative to THIS
    /// test file. `#filePath` returns the absolute path under SPM AND
    /// xcodebuild — unlike `#file`, which Xcode helpfully turns into a
    /// relative path under the simulator sandbox.
    private static func readerUIDir() -> URL {
        // #filePath → .../RishiReader/Tests/RishiReaderTests/A11y/ReaderA11yLabelsTests.swift
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent()   // A11y/
            .deletingLastPathComponent()   // RishiReaderTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // RishiReader/ (package root)
        return packageRoot
            .appendingPathComponent("Sources/RishiReader/UI", isDirectory: true)
    }

    private static func readerSources() throws -> [URL] {
        let dir = readerUIDir()
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "swift" }
    }

    @Test("No fixed-size .font(.system(size:)) in reader chrome (Dynamic Type / A11Y-02)")
    func noFixedFontSizes() throws {
        for url in try Self.readerSources() {
            let s = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !s.contains(".font(.system(size:"),
                "Fixed font size in \(url.lastPathComponent) violates Dynamic Type (A11Y-02)"
            )
        }
    }

    @Test("No raw .animation( in reader chrome (Reduce Motion / A11Y-03)")
    func noRawAnimation() throws {
        for url in try Self.readerSources() {
            let s = try String(contentsOf: url, encoding: .utf8)
            // `.rishiAnimation(` is allowed; any other `.animation(` is a
            // bypass of the Reduce Motion gate.
            let lines = s.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip doc-comment lines.
                if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { continue }
                if line.contains(".animation(") && !line.contains(".rishiAnimation(") {
                    Issue.record(
                        "Raw .animation( in \(url.lastPathComponent):\(idx + 1) — use .rishiAnimation(_:reduce:)"
                    )
                }
            }
        }
    }

    @Test("Reader toolbar buttons declare accessibilityLabel from A11yLabel")
    func toolbarButtonsCarryLabels() throws {
        // Phase 18 Plan 18-07 (F-P1-05) — the standalone overlay toolbar
        // files were deleted in favor of native `.toolbar { ToolbarItemGroup }`
        // blocks living inside the reader screens themselves. Assertions
        // now run against the screen source files.
        let screens = ["PDFReaderScreen.swift", "ReaderScreen.swift"]
        for url in try Self.readerSources() where screens.contains(url.lastPathComponent) {
            let s = try String(contentsOf: url, encoding: .utf8)
            // Every reader screen references the shared A11yLabel
            // vocabulary at least once — this guarantees we're not
            // duplicating strings.
            #expect(
                s.contains("A11yLabel."),
                "\(url.lastPathComponent) should source labels from A11yLabel"
            )
            // Phase 18 Plan 18-01 (F-P0-02) — the in-app close button
            // (`A11yLabel.readerClose`) was deleted in favor of the system
            // NavigationStack back chevron, so it's no longer asserted.
            #expect(s.contains("A11yLabel.readerOpenTOC"))
            #expect(s.contains("A11yLabel.readerOpenTheme"))
        }
    }

    @Test("HighlightContextMenu uses A11yLabel for highlight verbs")
    func highlightMenuLabels() throws {
        let url = try Self.readerSources().first { $0.lastPathComponent == "HighlightContextMenu.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(s.contains("A11yLabel.readerHighlightColor"))
        #expect(s.contains("A11yLabel.readerAddNote"))
        #expect(s.contains("A11yLabel.readerDeleteHighlight"))
        // Identifiers used by UI tests in plan 12-06.
        #expect(s.contains("highlight.color."))
        #expect(s.contains("highlight.addNote"))
        #expect(s.contains("highlight.delete"))
    }

    @Test("Toolbar buttons declare stable accessibility identifiers")
    func toolbarIdentifiers() throws {
        // Phase 18 Plan 18-07 (F-P1-05) — identifiers now live inside the
        // screens' `.toolbar { ToolbarItemGroup }` blocks (the standalone
        // overlay toolbar files were deleted). Source files to scan
        // migrated accordingly.
        let pdfURL = try Self.readerSources().first { $0.lastPathComponent == "PDFReaderScreen.swift" }
        try #require(pdfURL != nil)
        let pdf = try String(contentsOf: pdfURL!, encoding: .utf8)
        // Phase 18 Plan 18-01 (F-P0-02) — the legacy in-app close
        // identifier was removed when the `xmark` button was deleted in
        // favor of the system NavigationStack back chevron, so it's no
        // longer listed below.
        let pdfIds = [
            "reader.toolbar.toc",
            "reader.toolbar.theme",
            // Phase 37 Plan 37-02 — PDF bookmark toggle + list buttons.
            "reader.toolbar.bookmark",
            "reader.toolbar.bookmarksList",
            // Phase 37 Plan 37-04 — in-book search button.
            "reader.toolbar.search",
            "reader.toolbar.readAloud",
            "reader.toolbar.voice",
        ]
        for id in pdfIds {
            #expect(pdf.contains(id), "PDFReaderScreen missing identifier \(id)")
        }

        let epubURL = try Self.readerSources().first { $0.lastPathComponent == "ReaderScreen.swift" }
        try #require(epubURL != nil)
        let epub = try String(contentsOf: epubURL!, encoding: .utf8)
        // Phase 37 Plan 37-03 added the EPUB bookmark toggle + bookmarks-list
        // buttons; the EPUB toolbar now carries its typography button plus the
        // two bookmark ids. Plan 37-05 adds the in-book search id.
        let epubIds = [
            "reader.toolbar.toc",
            "reader.toolbar.theme",
            "reader.toolbar.bookmark",
            "reader.toolbar.bookmarksList",
            "reader.toolbar.search",
            "reader.toolbar.readAloud",
            "reader.toolbar.voice",
            "reader.toolbar.typography",
        ]
        for id in epubIds {
            #expect(epub.contains(id), "ReaderScreen missing identifier \(id)")
        }
    }

    @Test("Toolbar accessibilityIdentifier sites match the screen's static identifier list")
    func toolbarButtonsLabelled() throws {
        // Phase 18 Plan 18-07 (F-P1-05) — with the overlay toolbar files
        // deleted, the toolbar Button call sites now sit inline inside
        // each screen's `.toolbar { ToolbarItemGroup }` block, mixed in
        // with unrelated highlight-menu / picker buttons. Counting raw
        // `Button(...)` call sites in the whole file would over-count.
        // Instead we count the `reader.toolbar.*` accessibility-identifier
        // sites and assert they equal the expected list (no more, no
        // fewer). If the runtime block grows or shrinks the test will
        // flag the mismatch.
        let expectedByFile: [String: Int] = [
            // Phase 37 Plan 37-03 added the EPUB bookmark toggle + bookmarks-list
            // identifier sites (5 -> 7); Plan 37-05 added the search button
            // (7 -> 8).
            "ReaderScreen.swift": 8,
            // Phase 37 Plan 37-02 added the bookmark toggle + bookmarks-list
            // identifier sites (4 -> 6); Plan 37-04 added the search button
            // (6 -> 7).
            "PDFReaderScreen.swift": 7,
        ]
        for url in try Self.readerSources() where expectedByFile.keys.contains(url.lastPathComponent) {
            let s = try String(contentsOf: url, encoding: .utf8)
            let idSites = s.components(separatedBy: ".accessibilityIdentifier(\"reader.toolbar.").count - 1
            let expected = expectedByFile[url.lastPathComponent]!
            #expect(
                idSites == expected,
                "\(url.lastPathComponent): expected \(expected) reader.toolbar.* identifier sites, found \(idSites)"
            )
        }
    }
}
