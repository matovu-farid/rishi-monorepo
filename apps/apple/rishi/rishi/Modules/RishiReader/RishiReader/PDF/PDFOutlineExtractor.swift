import Foundation
import PDFKit

/// Converts a `PDFDocument.outlineRoot` into an immutable `PDFOutlineNode`
/// tree. Empty array for outline-less PDFs (which is most public-domain
/// books — no exception thrown).
///
/// Runs synchronously; outline trees are typically <1000 nodes. If a real-
/// world PDF surfaces a deeper tree, push extraction to `Task.detached`.
public enum PDFOutlineExtractor {

    public static func extract(from document: PDFDocument) -> [PDFOutlineNode] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { idx in
            guard let child = root.child(at: idx) else { return nil }
            return makeNode(child, document: document)
        }
    }

    private static func makeNode(_ outline: PDFOutline, document: PDFDocument) -> PDFOutlineNode {
        let label = outline.label ?? "Untitled"
        let pageIndex: Int? = {
            guard let page = outline.destination?.page else { return nil }
            let idx = document.index(for: page)
            return idx >= 0 ? idx : nil
        }()
        let children = (0..<outline.numberOfChildren).compactMap { idx in
            outline.child(at: idx).map { makeNode($0, document: document) }
        }
        return PDFOutlineNode(label: label, pageIndex: pageIndex, children: children)
    }
}
