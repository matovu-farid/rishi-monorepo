import Foundation
import Testing
@testable import RishiLibrary
import RishiCore
import RishiTesting

/// Regression: Phase 21 Plan 21-01 wired `LibraryRootView.coverURL` to
/// `vm.coverURLs`, which is populated only by the nonisolated HEIC-cache
/// fast path (`BookFileStorage.cachedCoverURLIfFresh`). The HEIC cache is
/// never populated during `BookFileStorage.importBook` — import only writes
/// the raw `cover.png` next to the book file. As a result, every newly
/// imported book stays cache-cold and renders the gradient fallback
/// instead of its extracted cover, even though the cover bytes are on
/// disk at `<root>/Books/<bookId>/cover.png`.
///
/// This suite asserts the user-observable contract: after `importBook`
/// followed by `vm.refresh()`, the imported book MUST have a non-nil
/// `coverURLs[book.id]` entry. The exact URL (HEIC cache vs raw PNG) is
/// an implementation detail — the test only checks that the URL is
/// present and points at a file that exists on disk.
@MainActor
@Suite("LibraryViewModel import cover regression")
struct LibraryViewModelImportCoverRegressionTests {

    @Test("refresh after importBook publishes a non-nil cover URL for EPUB")
    func refreshAfterImport_publishesCoverURL_forEPUB() async throws {
        let root = URL.temporaryDirectory
            .appendingPathComponent(
                "LVMImportCoverRegression-epub-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = URL.temporaryDirectory
            .appendingPathComponent(
                "LVMImportCoverRegression-epub-src-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let srcEPUB = srcDir.appendingPathComponent("alice.epub")
        try await FixtureBuilders.writeTinyEPUB(to: srcEPUB, withCover: true)

        let bookStore = InMemoryBookStore()
        let positionStore = InMemoryPositionStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ]
        )
        let userId = UUID()

        let imported = try await storage.importBook(from: srcEPUB, ownerId: userId)
        // Sanity — import extracted and wrote cover.png on disk.
        #expect(imported.coverPath != nil)

        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId })
        )
        await vm.refresh()

        #expect(vm.books.count == 1)
        // The load-bearing assertion — this fails on current main.
        let coverURL = vm.coverURLs[imported.id]
        #expect(coverURL != nil, "vm.coverURLs must publish a URL for newly imported EPUB")
        if let coverURL {
            #expect(
                FileManager.default.fileExists(atPath: coverURL.path),
                "Published cover URL must point at a file that exists on disk"
            )
        }
    }

    @Test("refresh after importBook publishes a non-nil cover URL for PDF")
    func refreshAfterImport_publishesCoverURL_forPDF() async throws {
        let root = URL.temporaryDirectory
            .appendingPathComponent(
                "LVMImportCoverRegression-pdf-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let srcDir = URL.temporaryDirectory
            .appendingPathComponent(
                "LVMImportCoverRegression-pdf-src-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }

        let srcPDF = srcDir.appendingPathComponent("alice.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let bookStore = InMemoryBookStore()
        let positionStore = InMemoryPositionStore()
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ]
        )
        let userId = UUID()

        let imported = try await storage.importBook(from: srcPDF, ownerId: userId)
        // Sanity — import extracted and wrote cover.png on disk.
        #expect(imported.coverPath != nil)

        let vm = LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId })
        )
        await vm.refresh()

        #expect(vm.books.count == 1)
        // The load-bearing assertion — this fails on current main.
        let coverURL = vm.coverURLs[imported.id]
        #expect(coverURL != nil, "vm.coverURLs must publish a URL for newly imported PDF")
        if let coverURL {
            #expect(
                FileManager.default.fileExists(atPath: coverURL.path),
                "Published cover URL must point at a file that exists on disk"
            )
        }
    }
}
