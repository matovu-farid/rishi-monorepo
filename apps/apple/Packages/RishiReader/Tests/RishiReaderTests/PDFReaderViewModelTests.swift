import Testing
import Foundation
import PDFKit
import RishiCore
import RishiTesting
@testable import RishiReader

@Suite("PDFReaderViewModel", .serialized)
struct PDFReaderViewModelTests {

    private func makeFixture(pageCount: Int, withOutline: Bool = true) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("vm-fix-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: pageCount, withOutline: withOutline)
        return url
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Fixture", formatType: .pdf, fileURL: "Books/x/fix.pdf")
    }

    @Test("PDFPositionEncoder round-trips")
    func encoderRoundTrips() {
        let enc = PDFPositionEncoder.encode(page: 42)
        #expect(enc == "pdf-v1:page:42")
        #expect(PDFPositionEncoder.decode(enc) == 42)
    }

    @Test("PDFPositionEncoder rejects malformed locator strings")
    func encoderRejectsMalformed() {
        #expect(PDFPositionEncoder.decode("epub-v1:cfi:/2[ch1]") == nil)
        #expect(PDFPositionEncoder.decode("pdf-v1:page:not-a-number") == nil)
        #expect(PDFPositionEncoder.decode("pdf-v1:page") == nil)
        #expect(PDFPositionEncoder.decode("") == nil)
    }

    @Test("load() restores last position from PositionStore")
    func loadRestoresLastPosition() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 5)
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed last position at page 3
        let seeded = Position(
            bookId: book.id,
            locator: PDFPositionEncoder.encode(page: 3),
            percentComplete: 0.6,
            updatedAt: Date()
        )
        try await store.upsert(seeded)

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        #expect(vm.totalPages == 5)
        #expect(vm.pageIndex == 3)
        #expect(vm.outline.count == 1)  // Part 1 root from fixture
    }

    @Test("didChangePage debounces position writes (~1s window)")
    func didChangePageDebouncesWrites() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 0.1
        )
        await vm.load()

        // Rapid-fire 5 page changes within debounce window
        for i in 1...5 { vm.didChangePage(toIndex: i) }
        // Wait > debounce window
        try await Task.sleep(for: .milliseconds(250))

        let last = try await store.position(for: book.id)
        #expect(last != nil)
        let stored = try #require(last.flatMap { PDFPositionEncoder.decode($0.locator) })
        // The LAST page wins (5), not any intermediate one
        #expect(stored == 5)
    }

    @Test("seek(toPage:) updates pageIndex and persists after debounce")
    func seekUpdatesAndPersists() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 0.05
        )
        await vm.load()

        vm.seek(toPage: 2)
        #expect(vm.pageIndex == 2)
        try await Task.sleep(for: .milliseconds(150))
        let last = try await store.position(for: book.id)
        #expect(PDFPositionEncoder.decode(last?.locator ?? "") == 2)
    }

    @Test("flush() writes immediately on dismiss, beating long debounce")
    func flushWritesImmediately() async throws {
        let store = InMemoryPositionStore()
        let book = makeBook()
        let userId = UUID()
        let url = try makeFixture(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PDFReaderViewModel(
            book: book, userId: userId,
            documentURL: url, positionStore: store,
            debounceSeconds: 5.0  // long debounce — flush must beat it
        )
        await vm.load()
        vm.didChangePage(toIndex: 2)
        await vm.flush()

        let last = try await store.position(for: book.id)
        #expect(PDFPositionEncoder.decode(last?.locator ?? "") == 2)
    }
}
