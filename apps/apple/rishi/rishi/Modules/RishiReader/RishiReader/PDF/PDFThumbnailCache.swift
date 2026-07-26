import Foundation
import PDFKit



#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Disk-backed thumbnail cache for the bottom page slider miniatures.
///
/// Storage:
/// - On-disk: `<Caches>/PDFThumbnails/<bookId>/<pageIndex>.jpg` (JPEG, q=0.7)
/// - In-memory: NSCache, countLimit = 32 (≈10 MB at our target size)
///
/// Reads:
/// 1. NSCache hit → return immediately
/// 2. Disk hit → load JPEG, install in NSCache, return
/// 3. Miss → render PDFPage on `Task.detached` inside `autoreleasepool`,
///    write JPEG, install in NSCache, return.
///
/// PDFKit's built-in slider thumbnail view is deliberately NOT used (PITFALLS
/// Pitfall 5): it caches rendered pages internally without bound, which OOMs on
/// 1000+ page PDFs.
public actor PDFThumbnailCache {

    public struct Configuration: Sendable {
        public var targetSize: CGSize
        public var memoryCountLimit: Int
        public var rootDirectory: URL

        public init(
            targetSize: CGSize = CGSize(width: 60, height: 80),
            memoryCountLimit: Int = 32,
            rootDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PDFThumbnails", isDirectory: true)
        ) {
            self.targetSize = targetSize
            self.memoryCountLimit = memoryCountLimit
            self.rootDirectory = rootDirectory
        }
    }

    private let config: Configuration
    // NSCache is thread-safe per Apple docs (TN1170 / NSCache header). We mark it
    // `nonisolated(unsafe)` so `memorySnapshotContains` (a `nonisolated` accessor
    // used by the page-slider fast path) can read it without an actor hop.
    private nonisolated(unsafe) let memory: NSCache<NSString, PlatformImage>

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = configuration.memoryCountLimit
        self.memory = cache
    }

    // MARK: - Public API

    /// Returns a thumbnail for `pageIndex` of the document at `documentURL`,
    /// scoped to `bookId` so deleting the book wipes all cached pages.
    public func thumbnail(
        bookId: BookID,
        documentURL: URL,
        pageIndex: Int
    ) async -> PlatformImage? {
        let memKey = memoryKey(bookId: bookId, pageIndex: pageIndex)
        if let cached = memory.object(forKey: memKey) { return cached }

        let onDisk = diskURL(bookId: bookId, pageIndex: pageIndex)
        if FileManager.default.fileExists(atPath: onDisk.path),
           let data = try? Data(contentsOf: onDisk),
           let image = PlatformImage(data: data) {
            memory.setObject(image, forKey: memKey)
            return image
        }

        // Render off the actor on a detached Task wrapped in autoreleasepool
        // so PDFKit/CG backing stores drain before we return (PITFALLS Pitfall 5).
        let size = config.targetSize
        let rendered: PlatformImage? = await Task.detached(priority: .utility) { () -> PlatformImage? in
            return autoreleasepool {
                guard let doc = PDFDocument(url: documentURL),
                      pageIndex >= 0,
                      pageIndex < doc.pageCount,
                      let page = doc.page(at: pageIndex) else {
                    return nil
                }
                return page.thumbnail(of: size, for: .mediaBox)
            }
        }.value

        guard let image = rendered else {
            Log.reader.warning("Thumbnail render failed for book=\(bookId.uuidString) page=\(pageIndex)")
            return nil
        }

        // Persist to disk (best-effort) and install in memory.
        try? FileManager.default.createDirectory(
            at: onDisk.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = jpegData(image, quality: 0.7) {
            try? data.write(to: onDisk, options: .atomic)
        }
        memory.setObject(image, forKey: memKey)
        return image
    }

    /// Drops all in-memory and on-disk thumbnails for a book — call this
    /// when a book is deleted in the Library.
    public func invalidate(for bookId: BookID) {
        // NSCache has no enumeration; drop the whole memory cache when
        // invalidating per book. countLimit keeps the working set bounded.
        memory.removeAllObjects()
        let dir = config.rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Synchronous in-memory hit-check used by tests and the page slider's
    /// fast path (avoid awaiting an actor hop when the cache is hot).
    /// NSCache reads are thread-safe per Apple docs.
    public nonisolated func memorySnapshotContains(
        bookId: BookID,
        pageIndex: Int
    ) -> Bool {
        memory.object(forKey: memoryKey(bookId: bookId, pageIndex: pageIndex)) != nil
    }

    // MARK: - Internals

    nonisolated func memoryKey(bookId: BookID, pageIndex: Int) -> NSString {
        "\(bookId.uuidString)/\(pageIndex)" as NSString
    }

    nonisolated func diskURL(bookId: BookID, pageIndex: Int) -> URL {
        config.rootDirectory
            .appendingPathComponent(bookId.uuidString, isDirectory: true)
            .appendingPathComponent("\(pageIndex).jpg")
    }
}

// MARK: - Platform image plumbing

#if canImport(UIKit)
public typealias PlatformImage = UIImage

private func jpegData(_ image: UIImage, quality: CGFloat) -> Data? {
    image.jpegData(compressionQuality: quality)
}
#elseif canImport(AppKit)
public typealias PlatformImage = NSImage

private func jpegData(_ image: NSImage, quality: CGFloat) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
}
#endif
