import Foundation
import ReadiumShared

/// Format-neutral position wrapper for the unified Readium reader.
///
/// The payload is the native Readium `Locator` JSON, so the same persisted
/// position shape works for EPUB and PDF publications.
public struct ReaderPositionLocator: Codable, Hashable, Sendable, JSONStringCodableLocator {
    public static let format = "reader-v1"
    static let jsonStringDecodeErrorLabel = "Reader position locator JSON is not valid UTF-8"

    public enum Source: String, Codable, Hashable, Sendable {
        case reader
        case readAloud
    }

    public let readiumLocator: String
    public let source: Source

    public init(locator: Locator, source: Source = .reader) {
        self.readiumLocator = (try? locator.jsonString()) ?? "{}"
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case readiumLocator
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        guard format == Self.format else {
            throw DecodingError.dataCorruptedError(
                forKey: .format,
                in: container,
                debugDescription: "Unsupported ReaderPositionLocator format \(format)"
            )
        }
        readiumLocator = try container.decode(String.self, forKey: .readiumLocator)
        // Older reader-v1 positions predate source tagging and are ordinary
        // reader positions, not guaranteed exact narration positions.
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .reader
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(readiumLocator, forKey: .readiumLocator)
        try container.encode(source, forKey: .source)
    }

    public func encodedJSONString() throws -> String {
        try encodedToJSONString()
    }

    public static func decode(jsonString: String) throws -> ReaderPositionLocator {
        try decoded(fromJSONString: jsonString)
    }

    public func toReadiumLocator() -> Locator? {
        try? Locator(jsonString: readiumLocator)
    }
}
