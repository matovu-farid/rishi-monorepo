import Foundation
import ReadiumZIPFoundation
import RishiLogging

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Extracts a cover image from an EPUB via ZIPFoundation.
///
/// Strategy (best-effort, returns nil on any failure):
///   1. Read `META-INF/container.xml` → find OPF root path.
///   2. Read the OPF → find the cover image href.
///      - EPUB 3: `<item properties="cover-image" href="…">`
///      - EPUB 2: `<meta name="cover" content="<idref>"/>` → `<item id="<idref>" href="…">`
///   3. Read the image entry, decode it to a PNG of `targetSize`.
///
/// This is the Pitfall 6 pattern (extract-to-memory for small EPUB assets +
/// regex-parse OPF). We are NOT trying to render the EPUB here — only pull
/// a single cover image. The Phase 6 Readium-based reader will own real
/// rendering.
public struct EpubCoverExtractor: CoverExtractor {
    public let targetSize: CGSize

    public init(targetSize: CGSize = CGSize(width: 600, height: 800)) {
        self.targetSize = targetSize
    }

    public func extractCover(from fileURL: URL) async -> Data? {
        let size = targetSize
        // Phase 20 structured-concurrency audit: this struct is `nonisolated`
        // (package default), so the function body already runs on the
        // cooperative executor — wrapping in `Task.detached` was redundant.
        // Every internal call is `await`-bound (`Archive` is an actor;
        // `readData` / `encodePNG` are nonisolated). Direct awaits preserve
        // off-main execution while restoring cancellation propagation and
        // priority inheritance from the caller.
        do {
            // ReadiumZIPFoundation 3.x: Archive is an actor; init and all access are async.
            let archive = try await Archive(url: fileURL, accessMode: .read)

            // 1) Locate the OPF path via META-INF/container.xml.
            guard let containerEntry = try await archive.get("META-INF/container.xml") else {
                throw CoverExtractionError.sourceUnreadable
            }
            let containerData = try await Self.readData(from: archive, entry: containerEntry)
            guard let opfRelativePath = Self.parseOpfPath(from: containerData) else {
                throw CoverExtractionError.noCoverEntry
            }

            // 2) Read the OPF and find the cover image href.
            guard let opfEntry = try await archive.get(opfRelativePath) else {
                throw CoverExtractionError.noCoverEntry
            }
            let opfData = try await Self.readData(from: archive, entry: opfEntry)
            guard let coverHref = Self.parseCoverHref(from: opfData) else {
                throw CoverExtractionError.noCoverEntry
            }

            // OPF item hrefs are relative to the OPF's own directory.
            let opfDir = (opfRelativePath as NSString).deletingLastPathComponent
            let coverPath = opfDir.isEmpty ? coverHref : "\(opfDir)/\(coverHref)"
            guard let coverEntry = try await archive.get(coverPath) else {
                throw CoverExtractionError.noCoverEntry
            }

            let imageData = try await Self.readData(from: archive, entry: coverEntry)

            // 3) Re-encode to a PNG of the target size so callers see a stable format.
            guard let png = Self.encodePNG(imageData, targetSize: size) else {
                throw CoverExtractionError.decodeFailed
            }
            return png
        } catch {
            Log.event(
                "cover.extract.epub.failed",
                level: .info,
                data: ["reason": "\(error)", "url": fileURL.lastPathComponent]
            )
            return nil
        }
    }

    // MARK: - ZIP read helper

    /// ReadiumZIPFoundation's `Consumer` is `@Sendable async throws`, so we cannot
    /// capture a mutable `var collected = Data()` directly. We funnel chunks through
    /// an actor-isolated collector to satisfy the Sendable boundary.
    private static func readData(from archive: Archive, entry: Entry) async throws -> Data {
        let collector = DataCollector()
        _ = try await archive.extract(entry) { @Sendable chunk in
            await collector.append(chunk)
        }
        return await collector.value
    }

    /// Thread-safe accumulator for streamed ZIP entry contents.
    private actor DataCollector {
        private(set) var value: Data = Data()
        func append(_ chunk: Data) {
            value.append(chunk)
        }
    }

    // MARK: - OPF / container parsing (internal for tests)

    /// container.xml looks like:
    ///   <rootfile full-path="OEBPS/content.opf" ...>
    /// EPUB containers are small and structurally fixed, so a regex parse is
    /// sufficient and avoids a full XML parser dependency.
    static func parseOpfPath(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"full-path\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Lookup order:
    ///   1. EPUB 3: `<item properties="cover-image" href="...">`
    ///   2. EPUB 2: `<meta name="cover" content="<idref>"/>`
    ///              → `<item id="<idref>" href="...">`
    static func parseCoverHref(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // EPUB 3 path — properties attribute can appear before OR after href.
        let epub3Patterns = [
            #"<item[^>]*properties\s*=\s*["'][^"']*\bcover-image\b[^"']*["'][^>]*href\s*=\s*["']([^"']+)["']"#,
            #"<item[^>]*href\s*=\s*["']([^"']+)["'][^>]*properties\s*=\s*["'][^"']*\bcover-image\b[^"']*["']"#,
        ]
        for pattern in epub3Patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }

        // EPUB 2 path.
        let metaPattern = #"<meta[^>]*name\s*=\s*["']cover["'][^>]*content\s*=\s*["']([^"']+)["']"#
        guard let metaRegex = try? NSRegularExpression(pattern: metaPattern),
              let metaMatch = metaRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let idRange = Range(metaMatch.range(at: 1), in: text) else { return nil }
        let coverId = String(text[idRange])

        let escapedId = NSRegularExpression.escapedPattern(for: coverId)
        let itemPattern = "<item[^>]*id\\s*=\\s*[\"']\(escapedId)[\"'][^>]*href\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern),
              let itemMatch = itemRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hrefRange = Range(itemMatch.range(at: 1), in: text) else { return nil }
        return String(text[hrefRange])
    }

    // MARK: - PNG re-encode

    private static func encodePNG(_ source: Data, targetSize: CGSize) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: source) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return scaled.pngData()
        #elseif canImport(AppKit)
        guard let image = NSImage(data: source),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(targetSize.width),
                pixelsHigh: Int(targetSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
        #else
        return source
        #endif
    }
}
