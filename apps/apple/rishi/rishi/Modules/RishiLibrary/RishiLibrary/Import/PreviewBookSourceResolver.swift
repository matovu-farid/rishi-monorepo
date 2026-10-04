import Foundation

/// Explicit read-only resolver for bundled previews and tests. It has no DB,
/// account identity, or managed-ready path.
public struct PreviewBookSourceResolver: BookSourceResolving, Sendable {
    private let urls: [BookID: URL]
    private let registry: BookSourceRegistry

    public init(urls: [BookID: URL]) {
        self.urls = urls
        registry = BookSourceRegistry(
            currentGeneration: { 0 },
            managedURL: { _ in nil }
        )
    }

    public func acquireReadableSource(for book: Book) async throws -> BookSourceLease {
        guard let url = urls[book.id], FileManager.default.fileExists(atPath: url.path) else {
            throw BookSourceRegistryError.unavailable
        }
        return await registry.registerPreview(for: book, url: url)
    }

    public func managedSource(for book: Book) async throws -> ManagedBookSource? { nil }

    public func awaitManagedSource(for book: Book) async throws -> ManagedBookSource {
        throw BookSourceRegistryError.managedSourceUnavailable
    }
}
