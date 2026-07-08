import Foundation
import Testing
import RishiCore
@testable import RishiReader

/// Phase 18 Plan 18-08 (F-P2-01) — invariant tests for the `ReaderSheet`
/// enum that drives the single `.sheet(item: $activeSheet)` modifier on
/// each reader screen.
///
/// We do NOT spin up SwiftUI here. The enum is a pure value type — its
/// invariants (Identifiable id stability, distinct ids per case, stable
/// id for the per-highlight editor case) can be exercised without a
/// runloop. SwiftUI's `.sheet(item:)` uses the same `id` projection at
/// runtime, so verifying the projection here proves the screen-level
/// behavior the runtime relies on.
@Suite("ReaderSheet")
struct ReaderSheetTests {

    // MARK: - Identifiable id stability

    @Test("id is stable across reads for the same case")
    func tocIdStable() {
        #expect(ReaderSheet.toc.id == ReaderSheet.toc.id)
        #expect(ReaderSheet.theme.id == ReaderSheet.theme.id)
        #expect(ReaderSheet.typography.id == ReaderSheet.typography.id)
        #expect(ReaderSheet.ttsControls.id == ReaderSheet.ttsControls.id)
        #expect(ReaderSheet.ttsPicker.id == ReaderSheet.ttsPicker.id)
        #expect(ReaderSheet.bookmarks.id == ReaderSheet.bookmarks.id)
        #expect(ReaderSheet.search.id == ReaderSheet.search.id)
    }

    // MARK: - Distinct cases yield distinct ids

    @Test("Distinct cases have distinct ids")
    func distinctIds() {
        let ids: Set<String> = [
            ReaderSheet.toc.id,
            ReaderSheet.typography.id,
            ReaderSheet.theme.id,
            ReaderSheet.ttsControls.id,
            ReaderSheet.ttsPicker.id,
            ReaderSheet.bookmarks.id,
            ReaderSheet.search.id,
        ]
        // All seven must be unique.
        #expect(ids.count == 7)
    }

    // MARK: - highlightNote id == highlight id

    @Test("highlightNote id is keyed by the underlying highlight id")
    func highlightNoteIdMatchesHighlight() {
        let bookId = UUID()
        let h = Highlight(
            bookId: bookId,
            locatorStart: "start",
            locatorEnd: "end",
            color: .yellow,
            text: "hello"
        )
        let sheet = ReaderSheet.highlightNote(h)
        // The id MUST embed the highlight's uuid so editing the same
        // highlight twice in a row does not re-mount the sheet.
        #expect(sheet.id.contains(h.id.uuidString))

        // Same highlight => same id (re-presenting same row does not bounce).
        let sheet2 = ReaderSheet.highlightNote(h)
        #expect(sheet.id == sheet2.id)

        // A different highlight => different id.
        let other = Highlight(
            bookId: bookId,
            locatorStart: "s2",
            locatorEnd: "e2",
            color: .pink,
            text: "world"
        )
        #expect(ReaderSheet.highlightNote(other).id != sheet.id)
    }

    // MARK: - All five content cases plus highlightNote exist

    @Test("Enum covers all reader sheet kinds")
    func coversAllKinds() {
        // Exhaustive switch — adding/removing a case forces this test
        // to be updated, which is the intent.
        let cases: [ReaderSheet] = [
            .toc,
            .typography,
            .theme,
            .ttsControls,
            .ttsPicker,
            .bookmarks,
            .search,
        ]
        for c in cases {
            switch c {
            case .toc, .typography, .theme, .ttsControls, .ttsPicker, .bookmarks, .search, .highlightNote:
                #expect(Bool(true))
            }
        }
    }

    // MARK: - Conformances

    @Test("ReaderSheet conforms to Identifiable + Hashable")
    func conformances() {
        // Identifiable: id projection compiles + returns a String.
        let _: String = ReaderSheet.toc.id

        // Hashable: enum can live in a Set + can be hashed.
        let set: Set<ReaderSheet> = [.toc, .theme, .typography]
        #expect(set.count == 3)
        #expect(set.contains(.toc))
        #expect(!set.contains(.ttsControls))
    }
}
