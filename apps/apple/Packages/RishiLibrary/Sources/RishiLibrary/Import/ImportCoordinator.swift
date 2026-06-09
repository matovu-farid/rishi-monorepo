import Foundation
import RishiCore
import RishiLogging

/// Bridges any URL-producing import surface (DocumentPicker, drag-drop, Open-In)
/// to `BookFileStorage.importBook(...)`. Owns:
///   1. Extension allow-list (matches `BookFormat` raw values).
///   2. Security-scoped resource acquire/release for picker-vended URLs.
///   3. Per-URL error capture so one bad file does not abort the batch.
public actor ImportCoordinator {

    public struct ImportOutcome: Sendable {
        public let url: URL
        public let book: Book?
        public let error: String?

        public init(url: URL, book: Book?, error: String?) {
            self.url = url
            self.book = book
            self.error = error
        }
    }

    /// Mirrors `BookFormat` raw values. Kept lower-cased; callers must lowercase
    /// the URL's `pathExtension` before checking.
    public static let allowedExtensions: Set<String> = ["epub", "pdf", "mobi", "azw3"]

    private let storage: BookFileStorage
    private let currentUserId: @Sendable () async -> UserID?

    /// `currentUserId` is a closure (not a stored `UserID`) so the coordinator
    /// re-reads the user identity at import time — important if the user signs
    /// out and back in between sessions.
    public init(
        storage: BookFileStorage,
        currentUserId: @escaping @Sendable () async -> UserID?
    ) {
        self.storage = storage
        self.currentUserId = currentUserId
    }

    /// Filter unsupported extensions before doing any work. Comparison is
    /// case-insensitive (e.g. `Foo.EPUB` passes).
    public static func filterSupported(_ urls: [URL]) -> [URL] {
        urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Import a batch of URLs. Each URL is treated independently: failures do
    /// not abort siblings. Caller is expected to surface aggregated results.
    ///
    /// Unsupported extensions are filtered out BEFORE any work — `BookFileStorage`
    /// would otherwise throw `.unsupportedFormat` for them.
    public func importBooks(_ urls: [URL]) async -> [ImportOutcome] {
        let supported = Self.filterSupported(urls)
        guard let userId = await currentUserId() else {
            Log.event(
                "library.import.skipped",
                level: .info,
                data: ["reason": "no_user", "count": String(supported.count)]
            )
            return supported.map { ImportOutcome(url: $0, book: nil, error: "no_user") }
        }
        var results: [ImportOutcome] = []
        results.reserveCapacity(supported.count)
        for url in supported {
            // Security-scoped resource dance — required for URLs vended by
            // UIDocumentPickerViewController. Harmless for plain file URLs
            // (returns false; nothing to balance).
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let book = try await storage.importBook(from: url, ownerId: userId)
                results.append(ImportOutcome(url: url, book: book, error: nil))
            } catch {
                Log.error("library.import.failed", error: error)
                results.append(ImportOutcome(url: url, book: nil, error: "\(error)"))
            }
        }
        return results
    }
}
