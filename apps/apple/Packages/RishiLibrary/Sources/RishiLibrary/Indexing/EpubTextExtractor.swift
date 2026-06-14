import Foundation
import ReadiumZIPFoundation
import RishiCore
import RishiLogging

/// EPUB text extractor. Closes RESEARCH OQ-1: chunk `page` integer is the
/// 1-based reading-order position of the spine resource the chunk came from,
/// NOT a visual page number. This mirrors Readium's `locator.locations.position`
/// concept without taking the full Readium dependency (RishiLibrary only
/// links `ReadiumZIPFoundation`, the ZIP archive subpackage).
///
/// Strategy (best-effort, mirrors `EpubMetadataExtractor` + `EpubCoverExtractor`):
///   1. Open the EPUB as a ZIP archive.
///   2. Read `META-INF/container.xml` -> find OPF root path.
///   3. Read the OPF -> walk the `<spine>` to recover spine item ids in order.
///   4. Resolve each spine id to its `<manifest>` `href` (relative to the OPF).
///   5. Read each spine resource's bytes, decode as UTF-8, strip HTML tags
///      coarsely (`<[^>]+>` -> space), then paragraph-chunk via
///      `RishiCore.ParagraphChunker.chunk(_:)`.
///   6. Emit one `(page: spineIndex + 1, text: chunk)` row per non-empty chunk.
///
/// Any failure (no container, no OPF, malformed XML, unreadable spine) is
/// downgraded to "no paragraphs" — the indexer treats that as a degenerate
/// but valid index and writes a `.ready` sidecar.
public struct EpubTextExtractor: PerBookTextExtractor {
    public init() {}

    public func extractParagraphs(
        from fileURL: URL
    ) async throws -> [(page: Int, text: String)] {
        do {
            let archive = try await Archive(url: fileURL, accessMode: .read)

            guard let containerEntry = try await archive.get("META-INF/container.xml") else {
                return []
            }
            let containerData = try await Self.readData(from: archive, entry: containerEntry)
            guard let opfRelativePath = EpubCoverExtractor.parseOpfPath(from: containerData) else {
                return []
            }

            guard let opfEntry = try await archive.get(opfRelativePath) else {
                return []
            }
            let opfData = try await Self.readData(from: archive, entry: opfEntry)

            let spineIds = Self.parseSpineItemIds(from: opfData)
            let manifest = Self.parseManifestHrefs(from: opfData)
            let opfDir = (opfRelativePath as NSString).deletingLastPathComponent

            var result: [(page: Int, text: String)] = []
            // 1-based reading-order position becomes our "page" integer per OQ-1.
            for (index, itemId) in spineIds.enumerated() {
                let position = index + 1
                guard let href = manifest[itemId] else { continue }
                let resourcePath = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
                guard let entry = try await archive.get(resourcePath) else { continue }
                let data = try await Self.readData(from: archive, entry: entry)
                guard let raw = String(data: data, encoding: .utf8) else { continue }
                let stripped = Self.stripHTML(raw)
                let chunks = ParagraphChunker.chunk(stripped)
                for chunk in chunks where !chunk.isEmpty {
                    result.append((page: position, text: chunk))
                }
            }
            return result
        } catch {
            Log.event(
                "rag.index.epub_extract.failed",
                level: .info,
                data: ["url": fileURL.lastPathComponent, "reason": "\(error)"]
            )
            return []
        }
    }

    // MARK: - OPF parsing

    /// Walk `<spine>` `<itemref idref="..."/>` in order.
    static func parseSpineItemIds(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        // Capture the spine block, then scan itemref idrefs within it.
        let spinePattern = #"<spine[^>]*>([\s\S]*?)</spine>"#
        guard let spineBody = Self.firstCapture(pattern: spinePattern, in: text) else {
            return []
        }
        var ids: [String] = []
        let itemrefPattern = #"<itemref[^>]*idref\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: itemrefPattern) else { return [] }
        let range = NSRange(spineBody.startIndex..., in: spineBody)
        regex.enumerateMatches(in: spineBody, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: spineBody) else { return }
            ids.append(String(spineBody[r]))
        }
        return ids
    }

    /// Parse `<manifest>` items into an `[id: href]` dictionary.
    static func parseManifestHrefs(from data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        let manifestPattern = #"<manifest[^>]*>([\s\S]*?)</manifest>"#
        guard let manifestBody = Self.firstCapture(pattern: manifestPattern, in: text) else {
            return [:]
        }
        var result: [String: String] = [:]
        // id-then-href and href-then-id orderings both appear in the wild.
        let itemPatterns = [
            #"<item[^>]*id\s*=\s*["']([^"']+)["'][^>]*href\s*=\s*["']([^"']+)["']"#,
            #"<item[^>]*href\s*=\s*["']([^"']+)["'][^>]*id\s*=\s*["']([^"']+)["']"#,
        ]
        for (orderIndex, pattern) in itemPatterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(manifestBody.startIndex..., in: manifestBody)
            regex.enumerateMatches(in: manifestBody, range: range) { match, _, _ in
                guard let match,
                      let firstRange = Range(match.range(at: 1), in: manifestBody),
                      let secondRange = Range(match.range(at: 2), in: manifestBody) else { return }
                let first = String(manifestBody[firstRange])
                let second = String(manifestBody[secondRange])
                // orderIndex 0 -> (id, href); 1 -> (href, id)
                let id = orderIndex == 0 ? first : second
                let href = orderIndex == 0 ? second : first
                if result[id] == nil {
                    result[id] = href
                }
            }
        }
        return result
    }

    /// Coarse HTML -> text. Drops script/style blocks first, then strips all
    /// remaining tags. Adequate for embedding-quality text; Readium's full
    /// content iterator would be cleaner but pulls in a heavier dep.
    static func stripHTML(_ raw: String) -> String {
        var text = raw
        // Drop script + style blocks wholesale.
        for blockPattern in [
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
        ] {
            if let regex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            }
        }
        // Strip remaining tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        return Self.decodeXMLEntities(text)
    }

    private static func decodeXMLEntities(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - ZIP read helper (mirrors EpubMetadataExtractor / EpubCoverExtractor)

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
}
