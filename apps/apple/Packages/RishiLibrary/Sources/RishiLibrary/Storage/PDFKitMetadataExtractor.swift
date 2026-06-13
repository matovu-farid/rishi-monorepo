import Foundation
import PDFKit
import RishiLogging

/// Reads the standard `Title` / `Author` keys from a PDF's
/// `documentAttributes` dictionary.
///
/// PDFKit exposes the document info dictionary via
/// `PDFDocument.documentAttributes`, keyed by `PDFDocumentAttribute.*`. The
/// title / author keys are not guaranteed to be present; we treat missing or
/// empty values as "no metadata" and let the import path fall back.
public struct PDFKitMetadataExtractor: MetadataExtractor {
    public init() {}

    public func extractMetadata(from fileURL: URL) async -> BookMetadata {
        // Open + read on a detached task so the PDFKit parse runs off the
        // calling actor (mirrors PDFKitCoverExtractor).
        await Task.detached(priority: .utility) {
            guard let doc = PDFDocument(url: fileURL) else {
                Log.event(
                    "metadata.extract.pdf.failed",
                    level: .info,
                    data: ["reason": "open_failed", "url": fileURL.lastPathComponent]
                )
                return BookMetadata()
            }
            let attrs = doc.documentAttributes ?? [:]
            let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
            let author = attrs[PDFDocumentAttribute.authorAttribute] as? String
            return BookMetadata(title: title, author: author)
        }.value
    }
}
