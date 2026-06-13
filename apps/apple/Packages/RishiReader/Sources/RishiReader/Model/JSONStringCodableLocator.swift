import Foundation

/// Internal protocol shared by the three persisted locator types
/// (``PDFHighlightLocator``, ``EPUBPositionLocator``,
/// ``EPUBHighlightLocator``).
///
/// All three persist as a UTF-8 JSON string in a `Highlight.locator*`
/// or `Position.locator` column. Each one used to roll its own
/// `encodedJSONString()` / `decode(jsonString:)` pair — identical
/// `JSONEncoder()` / `JSONDecoder()` plumbing wrapped around a
/// type-specific `Self`. This protocol holds the wiring in one place
/// so the three concrete types only declare the per-type error message
/// and forward the call.
///
/// Behaviour is identical to the inline implementations that preceded
/// it: default `JSONEncoder()` / `JSONDecoder()` (no date strategy —
/// locators carry no `Date` fields), UTF-8 round-trip, `DecodingError`
/// when the bytes are not valid UTF-8.
protocol JSONStringCodableLocator: Codable {
    /// Human-readable label used in the "not valid UTF-8" decode error
    /// for this locator type. The PDF/EPUB locators historically used
    /// slightly different wording; this preserves it.
    static var jsonStringDecodeErrorLabel: String { get }
}

extension JSONStringCodableLocator {

    /// Encodes `self` to a UTF-8 JSON string. Throws whatever
    /// `JSONEncoder.encode` throws.
    func encodedToJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a UTF-8 JSON string produced by ``encodedToJSONString()``.
    /// Throws `DecodingError.dataCorrupted` when `jsonString` is not
    /// valid UTF-8; otherwise forwards whatever `JSONDecoder.decode`
    /// throws (e.g. `dataCorruptedError` on a format-tag mismatch).
    static func decoded(fromJSONString jsonString: String) throws -> Self {
        guard let data = jsonString.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: jsonStringDecodeErrorLabel)
            )
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
