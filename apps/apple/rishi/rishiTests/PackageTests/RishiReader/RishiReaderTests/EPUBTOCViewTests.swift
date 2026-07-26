@testable import rishi
import Testing
import Foundation
import ReadiumShared


/// Logic tests for ``ReaderTOCView``. We don't spin up SwiftUI — the view is a
/// pure projection of `entries` + `onSelect`, so we cover the two behaviors
/// that matter: tapping a row forwards the link, and alice.epub actually
/// produces a non-empty TOC (manifest accessor).
///
/// **Sendability note:** Swift 6 strict rejects capturing a mutable test
/// `var` inside an `@escaping` closure stored on a struct ("non-Sendable
/// `(Link) -> ()` risks data races"). We sidestep that by routing tap
/// results through an `actor` collector — the closure becomes Sendable
/// because the only thing it captures is the actor reference.
@Suite("ReaderTOCView (logic)", .serialized)
struct ReaderTOCViewTests {

    /// Thread-safe collector for forwarded `Link` values. Lets the test
    /// closure stay Sendable while still letting us inspect what was passed.
    private actor SelectionRecorder {
        private(set) var last: ReadiumShared.Link?
        func record(_ link: ReadiumShared.Link) { last = link }
    }

    @Test("Tapping an entry invokes onSelect with the link")
    @MainActor
    func tapInvokesOnSelect() async {
        let recorder = SelectionRecorder()
        let link = ReadiumShared.Link(href: "chapter1.xhtml", title: "Chapter 1")
        let view = ReaderTOCView(
            entries: [link],
            onSelect: { tapped in
                Task { await recorder.record(tapped) }
            },
            onClose: { }
        )
        view.simulateSelection(for: view.entries[0])
        // Yield so the recorder Task can run before we read.
        try? await Task.sleep(for: .milliseconds(20))
        let captured = await recorder.last
        #expect(captured?.href == "chapter1.xhtml")
        #expect(captured?.title == "Chapter 1")
    }

    @Test("alice.epub TOC has at least one entry")
    func aliceTOCHasEntries() async throws {
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        let loader = PublicationLoader()
        let publication = try await loader.open(fileURL: url)
        let entries = publication.manifest.tableOfContents
        #expect(entries.count > 0)
    }
}

private extension ReaderTOCView {
    func simulateSelection(for link: ReadiumShared.Link) { onSelect(link) }
}
