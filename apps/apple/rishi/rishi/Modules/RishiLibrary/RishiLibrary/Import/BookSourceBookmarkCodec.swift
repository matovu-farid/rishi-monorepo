import Foundation

/// Encodes only opaque security-scoped bookmark data. A resolved URL is
/// runtime state and is never persisted in the materialization row.
public struct BookSourceBookmarkCodec: Sendable {
    public enum BookmarkError: Error, Sendable {
        case staleAttempt
    }

    public struct ResolvedBookmark: Sendable {
        public let url: URL
        public let refreshedData: Data?

        public init(url: URL, refreshedData: Data?) {
            self.url = url
            self.refreshedData = refreshedData
        }
    }

    public init() {}

    public func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        #if targetEnvironment(macCatalyst)
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        #if os(macOS)
        #if targetEnvironment(macCatalyst)
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        #else
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return (url, stale)
    }

    /// Refreshes stale permission data only if the persisted materialization
    /// attempt is still current. The caller must CAS-save refreshedData using
    /// the same token before exposing a restored source.
    public func resolveRefreshing(
        _ data: Data,
        isCurrentAttempt: @Sendable () async -> Bool
    ) async throws -> ResolvedBookmark {
        let resolved = try resolve(data)
        guard resolved.isStale else { return ResolvedBookmark(url: resolved.url, refreshedData: nil) }
        guard await isCurrentAttempt() else { throw BookmarkError.staleAttempt }
        return ResolvedBookmark(url: resolved.url, refreshedData: try makeBookmark(for: resolved.url))
    }
}
