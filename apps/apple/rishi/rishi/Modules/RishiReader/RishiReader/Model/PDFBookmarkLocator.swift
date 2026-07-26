import Foundation

/// JSON shape stored in a PDF bookmark row's `Bookmark.locator` field.
///
/// Schema (versioned via the `format` field):
/// ```json
/// {
///   "format": "pdf-bmk-v1",
///   "page": 42,
///   "snippet": "first line of the page"
/// }
/// ```
///
/// Mirrors ``PDFHighlightLocator`` but drops the `rects` selection geometry — a
/// PDF bookmark only needs the page index to jump to. `snippet` is an optional
/// context string for the bookmarks-list row.
///
/// The format tag distinguishes PDF bookmark locators (`pdf-bmk-v1`) from PDF
/// highlight locators (`pdf-v1`) and EPUB bookmark locators (`epub-bmk-v1`), so
/// a single locator string can be routed to the correct decoder by reading
/// `format` first.
///
/// **Sync contract:** this codec is the wire format for bookmark sync — changes
/// require a format bump (e.g. `pdf-bmk-v2`) and a decoder fallback that still
/// accepts `pdf-bmk-v1`.
public struct PDFBookmarkLocator: Codable, Hashable, Sendable, JSONStringCodableLocator {

    static let jsonStringDecodeErrorLabel = "Bookmark locator JSON is not valid UTF-8"

    /// Schema version tag emitted in encoded JSON.
    public static let format = "pdf-bmk-v1"

    public let page: Int
    public let snippet: String?

    public init(page: Int, snippet: String? = nil) {
        self.page = page
        self.snippet = snippet
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case format, page, snippet }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == Self.format else {
            throw DecodingError.dataCorruptedError(
                forKey: .format,
                in: c,
                debugDescription: "Unsupported PDFBookmarkLocator format \(format); expected \(Self.format)"
            )
        }
        self.page = try c.decode(Int.self, forKey: .page)
        self.snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(page, forKey: .page)
        try c.encodeIfPresent(snippet, forKey: .snippet)
    }

    // MARK: - Convenience JSON String accessors used by call sites

    /// Encodes to a UTF-8 JSON string suitable for storage in `Bookmark.locator`.
    public func encodedJSONString() throws -> String {
        try encodedToJSONString()
    }

    /// Decodes a UTF-8 JSON string produced by ``encodedJSONString()``.
    /// Throws `DecodingError` when the payload is malformed or the `format` tag
    /// does not match ``format``.
    public static func decode(jsonString: String) throws -> PDFBookmarkLocator {
        try decoded(fromJSONString: jsonString)
    }
}
