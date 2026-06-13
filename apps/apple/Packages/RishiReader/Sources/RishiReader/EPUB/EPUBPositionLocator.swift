import Foundation
import ReadiumShared

/// JSON shape stored in an EPUB position row's `Position.locator` field.
///
/// Schema (versioned via the `format` field):
/// ```json
/// {
///   "format": "epub-v1",
///   "readiumLocator": "<Readium Locator.jsonString() output>"
/// }
/// ```
///
/// The inner `readiumLocator` payload is whatever Readium produces from
/// `Locator.jsonString()` — typically `href` + `mediaType` + `locations`
/// (including `cfi` inside `otherLocations`) + `text` context. We do NOT
/// re-shape it; we wrap it. This keeps us trivially forward-compatible
/// when Readium adds fields.
///
/// The format tag distinguishes EPUB locators from PDF locators
/// (`pdf-v1`) so a single Highlight or Position row can be routed to
/// the correct decoder by reading `format` first.
///
/// **Phase 7 contract:** this codec is the wire format for sync —
/// changes require a format bump (e.g. `epub-v2`) and a decoder
/// fallback that still accepts `epub-v1`.
public struct EPUBPositionLocator: Codable, Hashable, Sendable, JSONStringCodableLocator {

    static let jsonStringDecodeErrorLabel = "Position locator JSON is not valid UTF-8"

    /// Schema version tag emitted in encoded JSON.
    public static let format = "epub-v1"

    /// The Readium-produced `Locator.jsonString()` payload as opaque JSON.
    public let readiumLocator: String

    public init(readiumLocator: String) {
        self.readiumLocator = readiumLocator
    }

    /// Convenience constructor that takes a Readium `Locator` and
    /// captures its JSON form.
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
                debugDescription: "Unsupported EPUBPositionLocator format \(format); expected \(Self.format)"
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

    /// Encodes to a UTF-8 JSON string suitable for storage in `Position.locator`.
    public func encodedJSONString() throws -> String {
        try encodedToJSONString()
    }

    /// Decodes a UTF-8 JSON string produced by ``encodedJSONString()``.
    public static func decode(jsonString: String) throws -> EPUBPositionLocator {
        try decoded(fromJSONString: jsonString)
    }

    /// Decodes the inner Readium `Locator` payload, if it parses.
    public func toReadiumLocator() -> Locator? {
        try? Locator(jsonString: readiumLocator)
    }
}
