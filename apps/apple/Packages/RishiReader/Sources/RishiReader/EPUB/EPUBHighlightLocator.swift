import Foundation
import ReadiumShared

/// JSON shape stored in an EPUB highlight row's `Highlight.locator` field.
///
/// Schema:
/// ```json
/// {
///   "format": "epub-v1",
///   "readiumLocator": "<Readium Locator.jsonString() output for the range>",
///   "text": "the selected text snippet"
/// }
/// ```
///
/// We persist the Readium `Locator` (whose `text.highlight` field holds
/// the snippet) AS-IS plus a redundant top-level `text` field so the
/// highlights list UI can render snippets without paying for a Readium
/// `Locator` deserialization on every row.
///
/// The format tag distinguishes EPUB highlights from PDF highlights
/// (`pdf-v1`).
///
/// **Phase 7 contract:** wire format for sync — bump to `epub-v2` if
/// the shape changes; decoder fallback must still accept `epub-v1`.
public struct EPUBHighlightLocator: Codable, Hashable, Sendable {

    public static let format = "epub-v1"

    /// Opaque Readium `Locator.jsonString()` for the range.
    public let readiumLocator: String

    /// Cached snippet text (also lives inside `readiumLocator.text.highlight`).
    public let text: String

    public init(readiumLocator: String, text: String) {
        self.readiumLocator = readiumLocator
        self.text = text
    }

    public init(locator: Locator) {
        self.readiumLocator = (try? locator.jsonString()) ?? "{}"
        self.text = locator.text.highlight ?? ""
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case format, readiumLocator, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == Self.format else {
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: c,
                debugDescription: "Unsupported EPUBHighlightLocator format \(format); expected \(Self.format)"
            )
        }
        self.readiumLocator = try c.decode(String.self, forKey: .readiumLocator)
        self.text = try c.decode(String.self, forKey: .text)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(readiumLocator, forKey: .readiumLocator)
        try c.encode(text, forKey: .text)
    }

    // MARK: - String round-trip

    public func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(jsonString: String) throws -> EPUBHighlightLocator {
        guard let data = jsonString.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Highlight locator JSON is not valid UTF-8")
            )
        }
        return try JSONDecoder().decode(EPUBHighlightLocator.self, from: data)
    }

    public func toReadiumLocator() -> Locator? {
        try? Locator(jsonString: readiumLocator)
    }
}
