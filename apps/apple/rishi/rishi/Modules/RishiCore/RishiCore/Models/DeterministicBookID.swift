import CryptoKit
import Foundation

extension UUID {
    /// RFC 4122 version-5 (SHA-1 namespace) UUID.
    public init(version5 namespace: UUID, name: String) {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        let digest = hasher.finalize()
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // version 5
        b[8] = (b[8] & 0x3F) | 0x80   // RFC 4122 variant
        self = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Derives a stable `BookID` from a book's metadata so the same book imported
/// on two devices (or under a different filename) collapses to one id and
/// dedupes through the sync upsert. Identity = normalized title + author +
/// format.
public enum DeterministicBookID {
    private static let namespace = UUID(uuidString: "9E1B6C42-7F3A-5D88-A1C4-2B5E0F7A9D31")!

    /// Returns a deterministic v5 `BookID` keyed off `title`, `author`, and
    /// `format`. Returns `nil` when the normalized title is empty so untitled
    /// books fall back to a random id rather than all collapsing into one.
    public static func make(title: String?, author: String?, format: BookFormat) -> BookID? {
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let normalizedAuthor = normalize(author)
        // 0x1F unit separator prevents field-boundary collisions.
        let name = normalizedTitle + "\u{1F}" + normalizedAuthor + "\u{1F}" + format.rawValue
        return UUID(version5: namespace, name: name)
    }

    private static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
