import Foundation
import ReadiumZIPFoundation


/// Phase 34 Plan 34-05 — filesystem/ZIP IO seam for ``EPUBUnpackedCache``.
///
/// Splits the raw on-disk side of the persistent EPUB unpack cache away from
/// the cache *policy* (freshness decision, in-flight coalescing, cancellation
/// gates). This type owns every operation that touches the filesystem or the
/// ZIP engine: URL/key derivation, directory existence, the `<bookId>.mtime`
/// sidecar codec, source-file mtime reads, mkdir/remove, and the `unzipItem`
/// call. The cache actor composes one of these and makes the policy decisions.
///
/// The protocol exists so the policy can be unit-tested with an in-memory fake
/// (no disk, no real ZIP). The concrete ``EPUBUnpackedFileSystemStore`` below is
/// the production implementation and reproduces the original cache's IO exactly
/// — same persisted layout, same sidecar format, same 1ms mtime tolerance — so
/// the on-disk format is unchanged across the refactor.
///
/// All methods are `nonisolated`/`Sendable`-safe: they use only
/// `FileManager.default` (documented thread-safe) and immutable configuration,
/// matching the original cache's nonisolated fast path.
public protocol EPUBUnpackedFileStore: Sendable {
    /// The unpacked-directory URL for `bookId` (key derivation).
    func unpackedDirectoryURL(for bookId: BookID) -> URL

    /// The mtime-sidecar URL for `bookId` (key derivation).
    func mtimeSidecarURL(for bookId: BookID) -> URL

    /// `true` if `url` exists AND is a directory.
    func directoryExists(at url: URL) -> Bool

    /// The cached mtime decoded from the sidecar at `url`, or nil if absent
    /// or unparseable.
    func readSidecarMtime(at url: URL) -> Date?

    /// The current modification date of the source file at `url`, or nil.
    func sourceMtime(at url: URL) -> Date?

    /// Encode + persist `mtime` to the sidecar at `url` (atomic, best-effort).
    func writeSidecarMtime(_ mtime: Date, to url: URL)

    /// Create `url` (and intermediates). Throws on failure.
    func createDirectory(at url: URL) throws

    /// Remove the item at `url` (best-effort, ignores "not found").
    func removeItem(at url: URL)

    /// Unzip `sourceFileURL` into `destination`. `async throws`; the ZIP
    /// engine is Readium's bundled `ReadiumZIPFoundation`.
    func unzip(sourceFileURL: URL, to destination: URL) async throws
}

/// Production ``EPUBUnpackedFileStore`` backed by the real filesystem and
/// Readium's bundled ZIP engine. Byte-for-byte preserves the original
/// ``EPUBUnpackedCache`` on-disk behaviour.
public struct EPUBUnpackedFileSystemStore: EPUBUnpackedFileStore {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func unpackedDirectoryURL(for bookId: BookID) -> URL {
        rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    public func mtimeSidecarURL(for bookId: BookID) -> URL {
        rootDirectory.appendingPathComponent("\(bookId.uuidString).mtime")
    }

    public func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        // FileManager.default is documented thread-safe; use it rather than the
        // captured instance so this stays safe across isolation domains.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    public func readSidecarMtime(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    public func sourceMtime(at url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    public func writeSidecarMtime(_ mtime: Date, to url: URL) {
        let text = String(mtime.timeIntervalSince1970)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func unzip(sourceFileURL: URL, to destination: URL) async throws {
        // ReadiumZIPFoundation's unzipItem is an `async throws` extension on
        // FileManager. Invoke it on FileManager.default (documented Sendable)
        // so Swift 6 strict concurrency does not flag sending a stored
        // FileManager across the nonisolated async boundary.
        try await FileManager.default.unzipItem(at: sourceFileURL, to: destination)
    }
}
