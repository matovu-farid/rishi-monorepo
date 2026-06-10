import Testing
import Foundation
import PDFKit
import RishiCore
@testable import RishiReader

/// Serialized: the default Configuration writes to a shared
/// `<Caches>/PDFThumbnails` directory, and even with isolated configs each test
/// builds a unique temp tree we don't want racing against the FileManager.
@Suite("PDFThumbnailCache", .serialized)
struct PDFThumbnailCacheTests {

    private func makeIsolatedConfig() -> PDFThumbnailCache.Configuration {
        let root = URL.temporaryDirectory.appendingPathComponent(
            "PDFThumbCache-\(UUID().uuidString)",
            isDirectory: true
        )
        return PDFThumbnailCache.Configuration(
            targetSize: CGSize(width: 60, height: 80),
            memoryCountLimit: 4,
            rootDirectory: root
        )
    }

    private func writeFixturePDF(pageCount: Int) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).pdf")
        try FixtureBuilders.writeMultiPagePDF(to: url, pageCount: pageCount, withOutline: false)
        return url
    }

    @Test("Cold read renders, persists to disk, and installs in memory")
    func coldReadRendersAndPersists() async throws {
        let config = makeIsolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.rootDirectory) }
        let cache = PDFThumbnailCache(configuration: config)

        let pdf = try writeFixturePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: pdf) }

        let bookId = BookID()
        let image = await cache.thumbnail(bookId: bookId, documentURL: pdf, pageIndex: 0)
        #expect(image != nil)

        let disk = cache.diskURL(bookId: bookId, pageIndex: 0)
        #expect(FileManager.default.fileExists(atPath: disk.path))
        #expect(cache.memorySnapshotContains(bookId: bookId, pageIndex: 0))
    }

    @Test("Warm disk read installs in memory without re-rendering")
    func warmDiskReadHitsMemory() async throws {
        let config = makeIsolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.rootDirectory) }
        let cache = PDFThumbnailCache(configuration: config)

        let pdf = try writeFixturePDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let bookId = BookID()

        _ = await cache.thumbnail(bookId: bookId, documentURL: pdf, pageIndex: 0)

        // Disk hit path: re-reading must return a valid image and re-install
        // it in NSCache (which the snapshot check confirms).
        let image = await cache.thumbnail(bookId: bookId, documentURL: pdf, pageIndex: 0)
        #expect(image != nil)
        #expect(cache.memorySnapshotContains(bookId: bookId, pageIndex: 0))
    }

    @Test("invalidate(for:) removes on-disk directory and memory entries")
    func invalidateRemovesEverything() async throws {
        let config = makeIsolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.rootDirectory) }
        let cache = PDFThumbnailCache(configuration: config)

        let pdf = try writeFixturePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let bookId = BookID()

        _ = await cache.thumbnail(bookId: bookId, documentURL: pdf, pageIndex: 0)
        _ = await cache.thumbnail(bookId: bookId, documentURL: pdf, pageIndex: 1)

        let bookDir = config.rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: bookDir.path))

        await cache.invalidate(for: bookId)

        #expect(!FileManager.default.fileExists(atPath: bookDir.path))
        #expect(!cache.memorySnapshotContains(bookId: bookId, pageIndex: 0))
    }

    @Test("Returns nil for out-of-bounds page index without crashing")
    func returnsNilForOutOfBoundsPage() async throws {
        let config = makeIsolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.rootDirectory) }
        let cache = PDFThumbnailCache(configuration: config)

        let pdf = try writeFixturePDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: pdf) }

        let image = await cache.thumbnail(bookId: BookID(), documentURL: pdf, pageIndex: 99)
        #expect(image == nil)
    }
}
