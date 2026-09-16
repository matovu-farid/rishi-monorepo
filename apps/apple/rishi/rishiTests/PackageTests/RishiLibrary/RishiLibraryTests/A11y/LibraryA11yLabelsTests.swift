@testable import rishi
import Foundation
import Testing

/// File-level invariants for library UI accessibility.
@Suite("Library a11y — file-level invariants")
struct LibraryA11yLabelsTests {

    private static func libraryViewsDir() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here
            .deletingLastPathComponent()   // A11y/
            .deletingLastPathComponent()   // RishiLibraryTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // RishiLibrary/ (package root)
        return packageRoot
            .appendingPathComponent("Sources/RishiLibrary/Views", isDirectory: true)
    }

    private static func librarySources() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: libraryViewsDir(), includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "swift" }
    }

    @Test("No fixed-size .font(.system(size:)) in library UI (A11Y-02)")
    func noFixedFontSizes() throws {
        for url in try Self.librarySources() {
            let s = try String(contentsOf: url, encoding: .utf8)
            #expect(
                !s.contains(".font(.system(size:"),
                "Fixed font size in \(url.lastPathComponent) violates Dynamic Type"
            )
        }
    }

    @Test("No raw .animation( in library UI (A11Y-03)")
    func noRawAnimation() throws {
        for url in try Self.librarySources() {
            let s = try String(contentsOf: url, encoding: .utf8)
            let lines = s.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("///") || trimmed.hasPrefix("//") { continue }
                if line.contains(".animation(") && !line.contains(".rishiAnimation(") {
                    Issue.record(
                        "Raw .animation( in \(url.lastPathComponent):\(idx + 1) — use .rishiAnimation(_:reduce:)"
                    )
                }
            }
        }
    }

    @Test("LibraryGrid cells expose <title> by <author> accessibility labels")
    func libraryGridLabels() throws {
        let url = try Self.librarySources().first { $0.lastPathComponent == "LibraryGrid.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(s.contains(".accessibilityLabel("))
        // The required pattern from A11Y-01.
        #expect(s.contains("by \\(author)") || s.contains("by \\(author"))
        // Delete confirmation labels each book individually.
        #expect(s.contains("Delete \\(book.title)"))
        // Hint guides VoiceOver users on how to interact.
        #expect(s.contains(".accessibilityHint("))
    }

    @Test("BookCoverImageView is decoratively hidden from VoiceOver")
    func bookCoverHidden() throws {
        let url = try Self.librarySources().first { $0.lastPathComponent == "BookCoverImageView.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(s.contains(".accessibilityHidden(true)"))
    }

    @Test("LibraryEmptyStateView uses RishiTypography, not fixed sizes")
    func emptyStateUsesTypography() throws {
        let url = try Self.librarySources().first { $0.lastPathComponent == "LibraryEmptyStateView.swift" }
        try #require(url != nil)
        let s = try String(contentsOf: url!, encoding: .utf8)
        #expect(!s.contains(".font(.system(size:"))
        #expect(s.contains("RishiTypography"))
    }
}
