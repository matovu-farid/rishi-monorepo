import Foundation
import ReadiumShared

/// JSON shape stored in an EPUB bookmark row's `Bookmark.locator` field.
///
/// Schema (versioned via the `format` field):
/// ```json
/// {
///   "format": "epub-bmk-v1",
///   "readiumLocator": "<Readium Locator.jsonString() output>"
/// }
/// ```
///
/// Mirrors ``EPUBPositionLocator``: we wrap the Readium-produced
/// `Locator.jsonString()` payload AS-IS rather than re-shaping it, which keeps
/// us forward-compatible when Readium adds fields. A bookmark only needs the
/// location, so there is no snippet/text field on the locator itself (the
/// `Bookmark.snippet` column carries any list-row context).
///
/// The format tag distinguishes EPUB bookmark locators (`epub-bmk-v1`) from
/// EPUB highlight/position locators (`epub-v1`) and PDF bookmark locators
/// (`pdf-bmk-v1`), so a single locator string can be routed to the correct
/// decoder by reading `format` first.
///
/// **Sync contract:** this codec is the wire format for bookmark sync — changes
/// require a format bump (e.g. `epub-bmk-v2`) and a decoder fallback that still
/// accepts `epub-bmk-v1`.
public struct EPUBBookmarkLocator: Codable, Hashable, Sendable, JSONStringCodableLocator {

    static let jsonStringDecodeErrorLabel = "Bookmark locator JSON is not valid UTF-8"

    /// Schema version tag emitted in encoded JSON.
    public static let format = "epub-bmk-v1"

    /// The Readium-produced `Locator.jsonString()` payload as opaque JSON.
    public let readiumLocator: String

    public init(readiumLocator: String) {
        self.readiumLocator = readiumLocator
    }

    /// Convenience constructor that takes a Readium `Locator` and captures its
    /// JSON form.
    public init(locator: Locator) {
        self.readiumLocator = (try? locator.jsonString()) ?? "{}"
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case format, readiumLocator }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == Self.format else {
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: c,
                debugDescription: "Unsupported EPUBBookmarkLocator format \(format); expected \(Self.format)"
            )
        }
        self.readiumLocator = try c.decode(String.self, forKey: .readiumLocator)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(readiumLocator, forKey: .readiumLocator)
    }

    // MARK: - String round-trip used by call sites

    /// Encodes to a UTF-8 JSON string suitable for storage in `Bookmark.locator`.
    public func encodedJSONString() throws -> String {
        try encodedToJSONString()
    }

    /// Decodes a UTF-8 JSON string produced by ``encodedJSONString()``.
    public static func decode(jsonString: String) throws -> EPUBBookmarkLocator {
        try decoded(fromJSONString: jsonString)
    }

    /// Decodes the inner Readium `Locator` payload, if it parses.
    public func toReadiumLocator() -> Locator? {
        try? Locator(jsonString: readiumLocator)
    }
}
