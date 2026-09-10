@testable import rishi
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

    /// Resolve the reader's consolidated `rishi/Modules/.../UI` directory relative to THIS
    /// test file. `#filePath` returns the absolute path under SPM AND
    /// xcodebuild — unlike `#file`, which Xcode helpfully turns into a
    /// relative path under the simulator sandbox.
    private static func readerUIDir() -> URL {
        // #filePath → .../RishiReader/Tests/RishiReaderTests/A11y/ReaderA11yLabelsTests.swift
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent()   // A11y/
            .deletingLastPathComponent()   // RishiReaderTests/
            .deletingLastPathComponent()   // RishiReader/ (package test group)
            .deletingLastPathComponent()   // PackageTests/
            .deletingLastPathComponent()   // rishiTests/
            .deletingLastPathComponent()   // rishi/ (app project root)
        return packageRoot
            .appendingPathComponent("rishi/Modules/RishiReader/RishiReader/UI", isDirectory: true)
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
            let lines = s.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() where line.contains(".font(.system(size:") {
                let preceding = lines[max(0, idx - 3)..<idx].joined(separator: "\n")
                // SF Symbol sizing is an icon treatment, not fixed text
                // typography; the EPUB edge arrows use this intentionally.
                if preceding.contains("Image(systemName:") { continue }
                Issue.record(
                    "Fixed text font size in \(url.lastPathComponent):\(idx + 1) violates Dynamic Type (A11Y-02)"
                )
            }
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
        // files were removed. EPUB owns its toolbar in ReaderScreen.swift.
        // PDFReaderScreen.swift
        // applies the shared ReaderToolBar modifier, so its labels live in
        // ToolBar.swift rather than in the screen wrapper.
        let requiredLabelsByFile: [String: [String]] = [
            "ReaderScreen.swift": [
                "A11yLabel.readerReadAloud",
                "A11yLabel.readerOpenVoice",
                "A11yLabel.readerOpenTypography",
                "A11yLabel.readerOpenTheme",
            ],
            "ToolBar.swift": [
                "A11yLabel.readerReadAloud",
                "A11yLabel.readerOpenVoice",
                "A11yLabel.readerOpenTheme",
            ],
        ]
        for url in try Self.readerSources()
            where requiredLabelsByFile.keys.contains(url.lastPathComponent) {
            let s = try String(contentsOf: url, encoding: .utf8)
            for label in requiredLabelsByFile[url.lastPathComponent]! {
                #expect(s.contains(label), "\(url.lastPathComponent) missing \(label)")
            }
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
        #expect(s.contains("A11yLabel.readerReadAloudFromHere"))
        // Identifiers used by UI tests in plan 12-06.
        #expect(s.contains("highlight.color."))
        #expect(s.contains("highlight.addNote"))
        #expect(s.contains("highlight.delete"))
        #expect(s.contains("highlight.readAloudFromHere"))
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
        let expectedByImplementation: [String: (source: String, identifiers: [String])] = [
            "ReaderScreen.swift": (
                source: "ReaderScreen.swift",
                identifiers: [
                    "reader.toolbar.toc",
                    "reader.toolbar.typography",
                    "reader.toolbar.theme",
                    "reader.toolbar.bookmark",
                    "reader.toolbar.bookmarksList",
                    "reader.toolbar.search",
                    "reader.toolbar.more",
                    "reader.toolbar.readAloud",
                    "reader.toolbar.voice",
                ]
            ),
            "PDFReaderScreen.swift": (
                source: "ToolBar.swift",
                identifiers: [
                    "reader.toolbar.toc",
                    "reader.toolbar.theme",
                    "reader.toolbar.bookmark",
                    "reader.toolbar.bookmarksList",
                    "reader.toolbar.search",
                    "reader.toolbar.more",
                    "reader.toolbar.readAloud",
                    "reader.toolbar.voice",
                ]
            ),
        ]
        let sources = try Self.readerSources()
        for (screen, contract) in expectedByImplementation {
            let implementation = try #require(
                sources.first { $0.lastPathComponent == contract.source },
                "Missing toolbar implementation \(contract.source) for \(screen)"
            )
            let s = try String(contentsOf: implementation, encoding: .utf8)
            let actualIdentifiers = Set(
                s.components(separatedBy: ".accessibilityIdentifier(\"").dropFirst().compactMap {
                    $0.split(separator: "\"").first.map(String.init)
                }
            )
            #expect(actualIdentifiers == Set(contract.identifiers))
        }
    }
}
