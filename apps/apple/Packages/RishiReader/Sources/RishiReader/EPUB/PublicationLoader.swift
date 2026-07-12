import Foundation
// `@preconcurrency` keeps the Readium 3.x non-Sendable types
// (Publication, Asset) from breaking the `PublicationLoading`
// protocol surface under Swift 6 strict-concurrency. The loader is
// invoked exactly once per book open and the returned `Publication`
// is consumed by a single awaiter; see ReaderViewModel.load() for
// the full transfer-region reasoning.
@preconcurrency import ReadiumShared
import ReadiumStreamer
import RishiCore
import RishiLogging

/// Errors emitted by ``PublicationLoader``.
public enum PublicationLoaderError: Error, Equatable {
    case invalidFileURL(URL)
    case assetRetrievalFailed(String)
    case publicationOpenFailed(String)
}

/// Protocol seam for the EPUB publication loader. Production code uses
/// ``PublicationLoader``; tests inject a probe to verify the open
/// body runs off the main thread (Phase 19 plan 19-09 — F-P0-08 EPUB
/// slice).
///
/// `Sendable` so callers (e.g. ``ReaderViewModel``) can hold the
/// loader across `Task.detached` boundaries without strict-concurrency
/// warnings.
public protocol PublicationLoading: Sendable {
    func open(fileURL: URL) async throws -> Publication
}

/// Resolves a Book's on-disk file URL → Readium `Publication` via the
/// 3.9 `AssetRetriever` + `PublicationOpener` + `DefaultPublicationParser`
/// pipeline (Spike A locked this exact shape).
///
/// **Phase 21 Plan 21-04 — warm directory cache.** Before invoking the
/// Readium pipeline this loader consults the injected ``EPUBUnpackedCache``:
///   1. If the cache holds a fresh unpacked directory for the EPUB's bookId,
///      open Readium against that directory URL (no per-launch ZIP unpack).
///   2. On cache miss, ask the cache to unpack the EPUB into its cache
///      directory and open Readium against the resulting directory URL.
///   3. On unpack failure OR if the file URL doesn't follow the
///      `<bookId>/<filename>.epub` layout (e.g. bundled fixtures during
///      tests), fall back to the original ZIP-asset path so the reader
///      never breaks because of a cache fault.
///
/// **Sendability:** Marked `final class ... Sendable` (compiler-proven, not
/// `@unchecked`) — the only stored property is `let unpackedCache:
/// EPUBUnpackedCache?` which is an actor (Sendable). The loader holds no
/// mutable cross-call state. The plan source called for an `actor`, but
/// Swift 6 strict concurrency forbids two things that pattern requires:
/// (1) sending stored non-Sendable `AssetRetriever`/`PublicationOpener`
/// references to their own nonisolated methods from `self`-isolated context,
/// and (2) returning the non-Sendable `Publication` from an actor-isolated
/// method to a nonisolated caller. The pipeline is built fresh per call
/// so non-Sendable Readium types stay as method-local references.
public final class PublicationLoader: PublicationLoading, Sendable {

    private let unpackedCache: EPUBUnpackedCache?

    /// Designated initialiser. Default `unpackedCache` is a system-caches
    /// backed instance so existing zero-arg call sites (
    /// `ReaderViewModel.init`, all bundled-fixture tests) pick up the
    /// warm-cache path automatically. Tests inject a temp-rooted cache via
    /// the parameter to scope on-disk state per test.
    ///
    /// Pass `nil` to disable the cache entirely (legacy ZIP-asset path
    /// only) — used by tests that want to assert the pre-Plan-21-04
    /// behaviour.
    public init(unpackedCache: EPUBUnpackedCache? = EPUBUnpackedCache()) {
        self.unpackedCache = unpackedCache
    }

    /// Opens the EPUB at `fileURL`. Throws on any failure in the
    /// retrieve → open pipeline.
    ///
    /// Per Phase 19 plan 19-09 (F-P0-08 EPUB slice): this body runs
    /// off-main when called from ``ReaderViewModel/load()`` because
    /// the view-model wraps the invocation in `Task.detached(priority:
    /// .userInitiated)`. The Readium `AssetRetriever.retrieve` and
    /// `PublicationOpener.open` calls are themselves `async` and
    /// nonisolated, so the awaited continuation also resumes off-main —
    /// the multi-second EPUB ZIP unpack never touches the main draw
    /// loop.
    ///
    /// Per Phase 21 Plan 21-04: the multi-second unpack is now a
    /// per-book ONE-TIME cost. Subsequent opens across app restarts skip
    /// the unpack and open against the cached directory.
    public func open(fileURL: URL) async throws -> Publication {
        // Resolve the warm-cache directory once (or nil if cold / not
        // applicable). We need this decision up-front because Readium's
        // AssetRetriever.retrieve(url:) does NOT accept a directory URL
        // — it treats the URL as a single resource to sniff for a
        // ZIP/EPUB container and rejects directories with
        // AssetRetrieveURLError. Instead, for a directory asset we
        // construct a DirectoryContainer and feed it to
        // retrieve(container:), which is the public API Readium exposes
        // for already-unpacked publications.
        let warmDirectory = await resolveWarmDirectoryURL(for: fileURL)

        // Build the pipeline fresh per call — keeps the non-Sendable
        // Readium objects as locals so Swift 6 strict concurrency is
        // satisfied. Per-call allocation cost is negligible compared
        // to the EPUB parse itself.
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        // Try the warm-cache directory-asset path first (when applicable).
        // Any failure here is non-fatal — we silently fall back to the
        // legacy ZIP-asset path so the user never gets a broken open
        // because of a cache-side issue.
        if let warmDirectory {
            if let asset = await retrieveDirectoryAsset(
                at: warmDirectory,
                assetRetriever: assetRetriever
            ) {
                do {
                    return try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
                } catch {
                    Log.reader.warning("Warm-cache PublicationOpener failed for \(fileURL.path, privacy: .public); falling back to ZIP-asset path: \(error.localizedDescription, privacy: .public)")
                    // fall through to the ZIP-asset path
                }
            } else {
                Log.reader.warning("Warm-cache AssetRetriever rejected directory for \(fileURL.path, privacy: .public); falling back to ZIP-asset path")
            }
        }

        // ZIP-asset path — the legacy default and the safe fallback.
        guard let readiumFileURL = FileURL(url: fileURL) else {
            throw PublicationLoaderError.invalidFileURL(fileURL)
        }

        let asset: Asset
        do {
            asset = try await assetRetriever.retrieve(url: readiumFileURL).get()
        } catch {
            Log.reader.error("AssetRetriever failed for \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw PublicationLoaderError.assetRetrievalFailed(error.localizedDescription)
        }

        do {
            return try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
        } catch {
            Log.reader.error("PublicationOpener failed for \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw PublicationLoaderError.publicationOpenFailed(error.localizedDescription)
        }
    }

    /// Builds a `DirectoryContainer` for the warm-cache directory and
    /// feeds it to `AssetRetriever.retrieve(container:)`. Returns `nil`
    /// on any failure so the caller falls back to the ZIP-asset path.
    private func retrieveDirectoryAsset(
        at directory: URL,
        assetRetriever: AssetRetriever
    ) async -> Asset? {
        guard let directoryFileURL = FileURL(url: directory) else { return nil }
        do {
            let container = try await DirectoryContainer(directory: directoryFileURL)
            return try await assetRetriever.retrieve(container: container).get()
        } catch {
            Log.reader.warning("DirectoryContainer/retrieve failed for \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Plan 21-04 cache resolution

    /// Returns the warm-cache directory URL for `fileURL`, or `nil` if
    /// the loader should use the ZIP-asset path directly.
    ///
    /// Returns `nil` for any of:
    ///   * no cache configured (init with `unpackedCache: nil`)
    ///   * bookId not derivable from the URL (e.g. bundled fixtures,
    ///     arbitrary picker URLs outside the BookFileStorage layout)
    ///   * the physical unpack failed (disk full, permission, ...)
    ///
    /// Returns the directory URL when the warm-cache fast path hits OR
    /// the slow-path unpack succeeded. Caller still safely falls back
    /// to the ZIP-asset path if Readium can't open the directory.
    private func resolveWarmDirectoryURL(for fileURL: URL) async -> URL? {
        guard let cache = unpackedCache,
              let bookId = Self.bookId(forFileURL: fileURL)
        else { return nil }

        if let warm = cache.unpackedDirectoryIfFresh(for: bookId, sourceFileURL: fileURL) {
            return warm
        }
        // Slow path: returns nil on unpack failure → caller falls back.
        return await cache.unpackIfNeeded(for: bookId, sourceFileURL: fileURL)
    }

    /// Derives the `BookID` from a `BookFileStorage`-managed file URL.
    ///
    /// The storage layout is `<booksDir>/<bookId.uuidString>/<filename>.<ext>`
    /// (see `BookFileStorage.importBook(from:ownerId:)`). The parent
    /// directory's last path component IS the bookId UUID string.
    ///
    /// Returns `nil` when the parent directory name is not a valid UUID
    /// (e.g. bundled test fixtures like `Bundle.module.url(forResource:
    /// "alice", withExtension: "epub")` whose parent is `Bundled`). The
    /// loader interprets `nil` as "use the legacy ZIP-asset path" so those
    /// call sites keep working unchanged.
    static func bookId(forFileURL fileURL: URL) -> BookID? {
        let parentName = fileURL.deletingLastPathComponent().lastPathComponent
        return UUID(uuidString: parentName)
    }
}
