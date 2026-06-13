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

        if fileManager.fileExists(atPath: coverURL.path),
           let cachedMtime = readMtime(at: mtimeURL),
           let currentMtime,
           cachedMtime == currentMtime {
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

    // MARK: - HEIC encode

    /// Re-encode the extractor's PNG payload as HEIC of `targetSize`. HEIC is
    /// significantly smaller than PNG at equivalent fidelity for cover
    /// thumbnails. Returns `nil` if the platform's `CGImageDestination`
    /// cannot encode HEIC (e.g. older simulators) — caller falls back to PNG.
    nonisolated static func encodeHEIC(_ pngData: Data, targetSize: CGSize) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: pngData)?.cgImage else { return nil }
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: pngData) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let image = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        #else
        return nil
        #endif

        let mutableData = NSMutableData()
        let heicType = UTType.heic.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            heicType,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
