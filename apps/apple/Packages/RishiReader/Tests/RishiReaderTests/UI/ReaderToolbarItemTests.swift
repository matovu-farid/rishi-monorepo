import Foundation
import Testing
@testable import RishiReader

/// Phase 18 Plan 18-07 (F-P1-05) — RED tests asserting that the reader
/// screens expose a stable list of accessibility identifiers for their
/// ToolbarItem buttons.
///
/// We deliberately do NOT spin up SwiftUI in these tests. On a macOS dev
/// host `swift test` cannot render `.toolbar { ToolbarItemGroup }` without
/// a real window + UIScene; the test harness would either deadlock waiting
/// for a runloop or silently report a stripped view tree. Instead, the
/// reader screens expose a `public static let toolbarAccessibilityIdentifiers`
/// array as the canonical source of truth — the same array is iterated
/// inside the screens' `.toolbar { ForEach(...) }` block at runtime, so a
/// drift between source-of-truth + render-time becomes a compile error.
///
/// Both arrays MUST exclude `reader.toolbar.close` — that identifier was
/// retired in Plan 18-01 when the in-app `xmark` button was deleted in
/// favor of the system NavigationStack back chevron.
@Suite("ReaderToolbarItem")
struct ReaderToolbarItemTests {

    @Test("EPUBReaderScreen exposes the five top-bar trailing identifiers")
    func epubIdentifiers() {
        let ids = EPUBReaderScreen.toolbarAccessibilityIdentifiers
        let expected: Set<String> = [
            "reader.toolbar.toc",
            "reader.toolbar.typography",
            "reader.toolbar.theme",
            "reader.toolbar.readAloud",
            "reader.toolbar.voice",
        ]
        #expect(Set(ids) == expected)
    }

    @Test("PDFReaderScreen exposes the six top-bar trailing identifiers (no typography)")
    func pdfIdentifiers() {
        let ids = PDFReaderScreen.toolbarAccessibilityIdentifiers
        let expected: Set<String> = [
            "reader.toolbar.toc",
            "reader.toolbar.theme",
            // Phase 37 Plan 37-02 — PDF bookmark toggle + bookmarks-list buttons.
            "reader.toolbar.bookmark",
            "reader.toolbar.bookmarksList",
            "reader.toolbar.readAloud",
            "reader.toolbar.voice",
        ]
        #expect(Set(ids) == expected)
    }

    @Test("Neither screen lists the retired reader.toolbar.close identifier")
    func closeIdentifierRetired() {
        #expect(!EPUBReaderScreen.toolbarAccessibilityIdentifiers.contains("reader.toolbar.close"))
        #expect(!PDFReaderScreen.toolbarAccessibilityIdentifiers.contains("reader.toolbar.close"))
    }
}
