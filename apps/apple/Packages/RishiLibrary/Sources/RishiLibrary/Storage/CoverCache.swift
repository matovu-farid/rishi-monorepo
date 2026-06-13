import Foundation
import ImageIO
import RishiLogging
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Disk cache for extracted book cover thumbnails.
///
/// Cold launch should not re-extract every cover — that costs IO + ZIP decode
/// per EPUB and a PDFKit page render per PDF. We persist the extracted PNG
/// from the extractor as a re-encoded HEIC under
/// `<rootURL>/book-covers/<bookID>.heic` (HEIC is ~5-10x smaller than PNG at
/// equivalent visual fidelity for the small cover thumbnails we render).
///
/// Invalidation: each cached cover sits next to a `<bookID>.mtime` sidecar
/// holding the source book file's last-modified timestamp at cache write
/// time. On `cachedURL(for:sourceFileURL:extractor:)` we re-stat the source;
/// if its mtime has changed since the sidecar, the cache is rebuilt.
public actor CoverCache {

    /// Root directory holding `<bookID>.heic` + `<bookID>.mtime` pairs.
    private let cacheDir: URL
    private let fileManager: FileManager

    /// Target render size for the cached thumbnail. Matches the library grid
    /// tile (2:3 portrait at ~280pt-wide on a stock iPhone simulator) with
    /// retina headroom.
    public let targetSize: CGSize

    public init(
        cacheDir: URL,
        targetSize: CGSize = CGSize(width: 600, height: 900),
        fileManager: FileManager = .default
    ) {
        self.cacheDir = cacheDir
        self.targetSize = targetSize
        self.fileManager = fileManager
    }

    /// Return a file URL pointing at the cached cover for `bookID`. If the
    /// cache is missing OR the source file's mtime has changed since the
    /// cached image was written, we re-extract via `extractor`, persist the
    /// result as HEIC, and return the new URL. Returns `nil` only when the
    /// extractor itself returns `nil` (and no usable cache was present).
    public func cachedURL(
        for bookID: UUID,
        sourceFileURL: URL,
        extractor: any CoverExtractor
    ) async -> URL? {
        ensureCacheDir()

        let coverURL = cacheURL(for: bookID)
        let mtimeURL = mtimeSidecarURL(for: bookID)
        let currentMtime = sourceMtime(at: sourceFileURL)

        // Phase 21 follow-up — compare mtimes with a sub-millisecond tolerance
        // because the sidecar stores `Date.timeIntervalSince1970` via
        // `String(_:)` which is not guaranteed to round-trip the full Double
        // precision of the in-memory value. Under the bit-exact comparison
        // previously used here, mtimes whose Double representation needs more
        // decimals than `String(_:)` emits would always miss the cache,
        // surfacing as the "covers take forever to come in" regression on
        // every paint (observed flakily by the pre-existing
        // `returnsCachedURL_withoutCallingExtractor_onHit` test).
        if fileManager.fileExists(atPath: coverURL.path),
           let cachedMtime = readMtime(at: mtimeURL),
           let currentMtime,
           Self.mtimesAreEqual(cachedMtime, currentMtime) {
            return coverURL
        }

        // Miss or stale: extract + persist.
        guard let pngData = await extractor.extractCover(from: sourceFileURL) else {
            return nil
        }
        guard let heicData = Self.encodeHEIC(pngData, targetSize: targetSize) else {
            // HEIC encode failure — fall back to writing PNG so we still
            // cache something. PNG is bigger but valid; better than re-
            // extracting on every cold launch.
            do {
                try pngData.write(to: coverURL, options: .atomic)
                if let currentMtime {
                    writeMtime(currentMtime, to: mtimeURL)
                }
                return coverURL
            } catch {
                Log.event(
                    "cover.cache.write.failed",
                    level: .info,
                    data: ["bookId": bookID.uuidString, "error": String(describing: error)]
                )
                return nil
            }
        }

        do {
            try heicData.write(to: coverURL, options: .atomic)
            if let currentMtime {
                writeMtime(currentMtime, to: mtimeURL)
            }
            return coverURL
        } catch {
            Log.event(
                "cover.cache.write.failed",
                level: .info,
                data: ["bookId": bookID.uuidString, "error": String(describing: error)]
            )
            return nil
        }
    }

    /// Clear the cached cover (and mtime sidecar) for a single book. Used
    /// when a book is deleted from the library.
    public func clear(_ bookID: UUID) {
        try? fileManager.removeItem(at: cacheURL(for: bookID))
        try? fileManager.removeItem(at: mtimeSidecarURL(for: bookID))
    }

    /// Test-only accessor for the underlying cache file path.
    public func _testCacheURL(for bookID: UUID) -> URL {
        cacheURL(for: bookID)
    }

    // MARK: - Internals

    private func cacheURL(for bookID: UUID) -> URL {
        cacheDir.appendingPathComponent("\(bookID.uuidString).heic")
    }

    private func mtimeSidecarURL(for bookID: UUID) -> URL {
        cacheDir.appendingPathComponent("\(bookID.uuidString).mtime")
    }

    /// Phase 21 perf — nonisolated cache-hit fast path. The library renders
    /// N tiles in parallel via `withTaskGroup`; each task previously had to
    /// hop onto this actor's single-threaded executor just to stat the
    /// already-warm HEIC sidecar, so the "concurrent" fan-out was secretly
    /// serialised behind the actor. By exposing the read-only cache-hit
    /// detection as `nonisolated`, all N stat syscalls truly run concurrently
    /// on the cooperative executor and the URL is returned without an actor
    /// hop. On cache MISS (or stale sidecar) we still fall back into
    /// `cachedURL(for:sourceFileURL:extractor:)` for the write path.
    ///
    /// Returns `nil` when the cache is cold OR the mtime sidecar is missing
    /// OR the source mtime drifted (caller falls back to the slow path).
    nonisolated func cachedURLIfFresh(
        for bookID: UUID,
        sourceFileURL: URL
    ) -> URL? {
        let coverURL = cacheDir.appendingPathComponent("\(bookID.uuidString).heic")
        let mtimeURL = cacheDir.appendingPathComponent("\(bookID.uuidString).mtime")
        let fm = FileManager.default
        guard fm.fileExists(atPath: coverURL.path),
              let cachedMtime = Self.readMtimeNonisolated(at: mtimeURL, fileManager: fm),
              let currentMtime = Self.sourceMtimeNonisolated(at: sourceFileURL, fileManager: fm),
              Self.mtimesAreEqual(cachedMtime, currentMtime)
        else { return nil }
        return coverURL
    }

    /// Nonisolated mtime parse for the fast-path; mirrors `readMtime(at:)`
    /// but takes `FileManager.default` (which is documented thread-safe) so
    /// it can run on the cooperative executor without an actor hop.
    private nonisolated static func readMtimeNonisolated(at url: URL, fileManager: FileManager) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// Nonisolated source-mtime stat for the fast-path.
    private nonisolated static func sourceMtimeNonisolated(at url: URL, fileManager: FileManager) -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func ensureCacheDir() {
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }

    private func sourceMtime(at url: URL) -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func readMtime(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func writeMtime(_ date: Date, to url: URL) {
        let text = String(date.timeIntervalSince1970)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Phase 21 follow-up — equality comparator that tolerates the
    /// sub-millisecond drift introduced by writing the Date via
    /// `String(timeIntervalSince1970)` and reading it back via `TimeInterval(_:)`.
    /// 1ms tolerance is far below any meaningful file-modification granularity
    /// (HFS+/APFS expose sub-second mtimes but no app updates a book file
    /// twice within 1ms in practice) so this is purely defensive against the
    /// Double-string round-trip, never against a real edit.
    nonisolated static func mtimesAreEqual(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 0.001
    }

    // MARK: - HEIC encode

    /// Re-encode the extractor's PNG payload as a DOWNSAMPLED HEIC of
    /// `targetSize`. HEIC is significantly smaller than PNG at equivalent
    /// fidelity for cover thumbnails, AND the downsample is the load-bearing
    /// step — without it we'd be persisting (and then AsyncImage-decoding)
    /// the full 2000x3000 source image for every tile on every paint, which
    /// is the slow-cover-load regression users reported after Phase 21.
    ///
    /// Returns `nil` if the platform's `CGImageDestination` cannot encode
    /// HEIC (e.g. older simulators) — caller falls back to PNG.
    nonisolated static func encodeHEIC(_ pngData: Data, targetSize: CGSize) -> Data? {
        // Use ImageIO's CGImageSourceCreateThumbnailAtIndex pipeline — it
        // decodes only the pixels needed for the requested size instead of
        // decoding the full image and then resizing. For a 2000x3000 source
        // and a 600x900 target this is ~10x faster and uses ~10x less peak
        // memory than the prior UIImage(data:).cgImage round-trip.
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        let maxPixelSize = max(targetSize.width, targetSize.height)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        // Prefer the downsampled thumbnail (cheap decode, small output);
        // fall back to the full image when the source is too small or the
        // thumbnail creator refuses (e.g. degenerate 1x1 fixtures used in
        // unit tests). Either way we still HEIC-encode the result.
        let thumbnail: CGImage
        if let small = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            thumbnail = small
        } else if let full = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            thumbnail = full
        } else {
            return nil
        }

        let mutableData = NSMutableData()
        let heicType = UTType.heic.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            heicType,
            1,
            nil
        ) else { return nil }
        let encodeOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, thumbnail, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
