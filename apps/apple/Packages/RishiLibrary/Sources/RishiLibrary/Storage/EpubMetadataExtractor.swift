import Foundation
import ReadiumZIPFoundation
import RishiLogging

/// Extracts `<dc:title>` + `<dc:creator>` from an EPUB OPF.
///
/// Mirrors `EpubCoverExtractor`'s approach:
///   1. Read `META-INF/container.xml` → find OPF root path.
///   2. Read the OPF → regex-match `<dc:title>` and `<dc:creator>`.
///
/// Best-effort: any failure (missing container, malformed XML, no title) yields
/// `BookMetadata()` with nil fields. The import path then falls back to the
/// filename-derived title.
public struct EpubMetadataExtractor: MetadataExtractor {
    public init() {}

    public func extractMetadata(from fileURL: URL) async -> BookMetadata {
        do {
            let archive = try await Archive(url: fileURL, accessMode: .read)
            

            guard let containerEntry = try await archive.get("META-INF/container.xml") else {
                return BookMetadata()
            }
            let containerData = try await Self.readData(from: archive, entry: containerEntry)
            guard let opfRelativePath = EpubCoverExtractor.parseOpfPath(from: containerData) else {
                return BookMetadata()
            }

            guard let opfEntry = try await archive.get(opfRelativePath) else {
                return BookMetadata()
            }
            let opfData = try await Self.readData(from: archive, entry: opfEntry)

            let title = Self.parseDCTitle(from: opfData)
            let author = Self.parseDCCreator(from: opfData)
            return BookMetadata(title: title, author: author)
        } catch {
            Log.event(
                "metadata.extract.epub.failed",
                level: .info,
                data: ["reason": "\(error)", "url": fileURL.lastPathComponent]
            )
            return BookMetadata()
        }
    }

    // MARK: - ZIP read helper (mirrors EpubCoverExtractor.readData)

    private static func readData(from archive: Archive, entry: Entry) async throws -> Data {
        let collector = DataCollector()
        _ = try await archive.extract(entry) { @Sendable chunk in
            await collector.append(chunk)
        }
        return await collector.value
    }

    private actor DataCollector {
        private(set) var value: Data = Data()
        func append(_ chunk: Data) {
            value.append(chunk)
        }
    }

    // MARK: - OPF parsing (internal for tests)

    /// Matches `<dc:title>…</dc:title>` (with or without `dc:` prefix).
    /// Real-world OPFs use either `<dc:title>` (most common) or the unprefixed
    /// `<title>` inside the dc namespace. We allow both.
    static func parseDCTitle(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [
            #"<dc:title[^>]*>([^<]+)</dc:title>"#,
            #"<title[^>]*xmlns[^>]*purl\.org/dc[^>]*>([^<]+)</title>"#,
        ]
        for pattern in patterns {
            if let match = Self.firstCapture(pattern: pattern, in: text) {
                return Self.decodeXMLEntities(match)
            }
        }
        return nil
    }

    /// Matches `<dc:creator>…</dc:creator>` (with or without `dc:` prefix).
    /// Some OPFs add a `role` attribute (e.g. `opf:role="aut"`); we accept any.
    static func parseDCCreator(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let patterns = [
            #"<dc:creator[^>]*>([^<]+)</dc:creator>"#,
            #"<creator[^>]*xmlns[^>]*purl\.org/dc[^>]*>([^<]+)</creator>"#,
        ]
        for pattern in patterns {
            if let match = Self.firstCapture(pattern: pattern, in: text) {
                return Self.decodeXMLEntities(match)
            }
        }
        return nil
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Decodes the small set of XML entities that show up in `<dc:*>` payloads
    /// (Calibre + Gutenberg emit `&amp;`, `&apos;`, etc.). We keep this minimal
    /// — full XML parsing isn't worth pulling in for a title field.
    private static func decodeXMLEntities(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
