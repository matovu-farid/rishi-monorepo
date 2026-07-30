import Foundation
@preconcurrency import PDFKit
@preconcurrency import ReadiumShared

/// Format-neutral source boundary used by later chapter-index generation.
/// Implementations return immutable values and never expose Readium or PDFKit
/// objects to callers.
public protocol ChapterSource: Sendable {
    func chapters() async -> ChapterSourceResult
}

/// Allocates stable IDs without relying on object identity or UUIDs.
enum ChapterSourceIDAllocator {
    static func id(base: String, occurrence: Int) -> String {
        occurrence == 0 ? base : "\(base)|duplicate-\(occurrence + 1)"
    }
}

/// Builds a value snapshot while the caller still owns the reader framework
/// object. These methods must be invoked in the owning reader context before
/// handing the resulting value to a `ChapterSource` actor.
private enum ChapterSourceSnapshotBuilder {
    static func epub(from publication: Publication) async -> ChapterSourceResult {
        let toc = publication.manifest.tableOfContents.flatMap(flatten)
        guard !toc.isEmpty else {
            return ChapterSourceResult(
                availability: .unavailable(diagnostics: ["EPUB publication has no table of contents"]),
                records: []
            )
        }

        var records: [ChapterSourceRecord] = []
        var diagnostics: [String] = []
        var occurrences: [String: Int] = [:]
        records.reserveCapacity(toc.count)

        for (sourcePosition, link) in toc.enumerated() {
            let href = link.href
            let baseID = "epub:\(href)"
            let occurrence = occurrences[baseID, default: 0]
            occurrences[baseID] = occurrence + 1
            let id = ChapterSourceIDAllocator.id(base: baseID, occurrence: occurrence)

            guard let resource = publication.get(link) else {
                diagnostics.append("EPUB resource unavailable: \(href)")
                continue
            }
            guard case .success(let html) = await resource.read().asString(encoding: .utf8) else {
                diagnostics.append("EPUB resource read failed: \(href)")
                continue
            }

            let text = ParagraphChunker.chunk(html).joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                diagnostics.append("EPUB resource contained no readable text: \(href)")
                continue
            }
            records.append(ChapterSourceRecord(
                id: id,
                name: link.title ?? href,
                sourcePosition: sourcePosition,
                locator: .epub(href: href),
                text: text
            ))
        }

        let availability: ChapterSourceResult.Availability
        if records.isEmpty {
            availability = .unavailable(diagnostics: diagnostics.isEmpty
                ? ["EPUB table of contents contained no readable chapters"]
                : diagnostics)
        } else if diagnostics.isEmpty {
            availability = .available
        } else {
            availability = .partialFailure(diagnostics: diagnostics)
        }
        return ChapterSourceResult(availability: availability, records: records)
    }

    static func pdf(from document: PDFKit.PDFDocument) -> ChapterSourceResult {
        let nodes = PDFOutlineExtractor.extract(from: document)
            .flatMap { $0.flattened() }
            .compactMap { node -> (PDFOutlineNode, Int)? in
                guard let page = node.pageIndex else { return nil }
                return (node, page)
            }
            .filter { $0.1 >= 0 && $0.1 < document.pageCount }
        guard !nodes.isEmpty else {
            return ChapterSourceResult(
                availability: .unavailable(diagnostics: ["PDF has no usable outline destinations"]),
                records: []
            )
        }

        var records: [ChapterSourceRecord] = []
        var diagnostics: [String] = []
        var occurrences: [String: Int] = [:]
        records.reserveCapacity(nodes.count)

        for (index, item) in nodes.enumerated() {
            let (node, startPage) = item
            let nextStart = nodes.dropFirst(index + 1).first?.1 ?? document.pageCount
            let endPage = max(startPage, min(document.pageCount - 1, nextStart - 1))
            let text = (startPage...endPage).compactMap { pageIndex in
                document.page(at: pageIndex).map { PDFReadAloudParagraphs.paragraphs(from: $0) }
            }.flatMap { $0 }.joined(separator: "\n\n")

            let baseID = "pdf:\(startPage):\(slug(node.label))"
            let occurrence = occurrences[baseID, default: 0]
            occurrences[baseID] = occurrence + 1
            let id = ChapterSourceIDAllocator.id(base: baseID, occurrence: occurrence)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append("PDF outline entry contained no readable text: \(node.label)")
            }
            records.append(ChapterSourceRecord(
                id: id,
                name: node.label,
                sourcePosition: index,
                locator: .pdf(pageRange: PDFChapterPageRange(startPage: startPage, endPage: endPage)),
                text: text
            ))
        }

        return ChapterSourceResult(
            availability: diagnostics.isEmpty ? .available : .partialFailure(diagnostics: diagnostics),
            records: records
        )
    }

    private static func flatten(_ link: Link) -> [Link] {
        [link] + link.children.flatMap(flatten)
    }

    private static func slug(_ label: String) -> String {
        let scalars = label.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return scalars.split(separator: "-").joined(separator: "-")
    }
}

/// Runtime source backed only by an immutable snapshot. Construct the
/// snapshot with `snapshot(from:)` in the owning EPUB reader context first.
public actor EPUBChapterSource: ChapterSource {
    private let snapshot: ChapterSourceResult

    public init(snapshot: ChapterSourceResult) {
        self.snapshot = snapshot
    }

    public static func snapshot(from publication: Publication) async -> ChapterSourceResult {
        await ChapterSourceSnapshotBuilder.epub(from: publication)
    }

    public func chapters() async -> ChapterSourceResult {
        snapshot
    }
}

/// Runtime source backed only by an immutable snapshot. Construct the
/// snapshot with `snapshot(from:)` in the owning PDF reader context first.
public actor PDFChapterSource: ChapterSource {
    private let snapshot: ChapterSourceResult

    public init(snapshot: ChapterSourceResult) {
        self.snapshot = snapshot
    }

    public static func snapshot(from document: PDFKit.PDFDocument) async -> ChapterSourceResult {
        ChapterSourceSnapshotBuilder.pdf(from: document)
    }

    public func chapters() async -> ChapterSourceResult {
        snapshot
    }
}
