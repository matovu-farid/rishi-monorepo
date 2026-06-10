import Foundation
import CoreGraphics

/// JSON shape stored in a PDF highlight's locator string (the value
/// later persisted into `RishiCore.Highlight.locatorStart` /
/// `locatorEnd` for PDF rows).
///
/// Schema (versioned via the `format` field):
/// ```json
/// {
///   "format": "pdf-v1",
///   "page": 42,
///   "rects": [[x0, y0, x1, y1], ...],
///   "text": "selected paragraph"
/// }
/// ```
///
/// Rectangles are stored in PDF user-space (origin lower-left, units
/// pt) for the page's mediaBox — NOT normalized [0,1] and NOT in
/// SwiftUI's coordinate space. The PDFKit selection coordinator
/// (Phase 05-06) is responsible for converting between PDFKit's
/// `PDFSelection` rects and this codec at the persistence boundary.
///
/// The format tag distinguishes PDF locators from the EPUB CFI shape
/// landing in Phase 6, so a single Highlight row's locator string can
/// be routed to the correct decoder by reading `format` first.
///
/// **Phase 7 contract:** this codec is the wire format for sync —
/// changes require a format bump (e.g. `pdf-v2`) and a decoder
/// fallback that still accepts `pdf-v1`.
public struct PDFHighlightLocator: Codable, Hashable, Sendable {

    /// Schema version tag emitted in encoded JSON.
    public static let format = "pdf-v1"

    public let page: Int
    public let rects: [CGRect]
    public let text: String

    public init(page: Int, rects: [CGRect], text: String) {
        self.page = page
        self.rects = rects
        self.text = text
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case format, page, rects, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == Self.format else {
            throw DecodingError.dataCorruptedError(
                forKey: .format,
                in: c,
                debugDescription: "Unsupported PDFHighlightLocator format \(format); expected \(Self.format)"
            )
        }
        self.page = try c.decode(Int.self, forKey: .page)
        let arrays = try c.decode([[CGFloat]].self, forKey: .rects)
        self.rects = arrays.map { a in
            let x0 = a[safe: 0] ?? 0
            let y0 = a[safe: 1] ?? 0
            let x1 = a[safe: 2] ?? 0
            let y1 = a[safe: 3] ?? 0
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        self.text = try c.decode(String.self, forKey: .text)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(page, forKey: .page)
        let arrays: [[CGFloat]] = rects.map { r in
            [r.minX, r.minY, r.maxX, r.maxY]
        }
        try c.encode(arrays, forKey: .rects)
        try c.encode(text, forKey: .text)
    }

    // MARK: - Convenience JSON String accessors used by call sites

    /// Encodes to a UTF-8 JSON string suitable for storage in
    /// `RishiCore.Highlight.locatorStart`.
    public func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a UTF-8 JSON string produced by ``encodedJSONString()``.
    /// Throws `DecodingError` when the payload is malformed or the
    /// `format` tag does not match ``format``.
    public static func decode(jsonString: String) throws -> PDFHighlightLocator {
        guard let data = jsonString.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Locator JSON is not valid UTF-8")
            )
        }
        return try JSONDecoder().decode(PDFHighlightLocator.self, from: data)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
