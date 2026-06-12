import Foundation
// `@preconcurrency` keeps the Readium 3.x non-Sendable types
// (Publication, Asset) from breaking the `EPUBPublicationLoading`
// protocol surface under Swift 6 strict-concurrency. The loader is
// invoked exactly once per book open and the returned `Publication`
// is consumed by a single awaiter; see EPUBReaderViewModel.load() for
// the full transfer-region reasoning.
@preconcurrency import ReadiumShared
import ReadiumStreamer
import RishiLogging

/// Errors emitted by ``EPUBPublicationLoader``.
public enum EPUBPublicationLoaderError: Error, Equatable {
    case invalidFileURL(URL)
    case assetRetrievalFailed(String)
    case publicationOpenFailed(String)
}

/// Protocol seam for the EPUB publication loader. Production code uses
/// ``EPUBPublicationLoader``; tests inject a probe to verify the open
/// body runs off the main thread (Phase 19 plan 19-09 — F-P0-08 EPUB
/// slice).
///
/// `Sendable` so callers (e.g. ``EPUBReaderViewModel``) can hold the
/// loader across `Task.detached` boundaries without strict-concurrency
/// warnings.
public protocol EPUBPublicationLoading: Sendable {
    func open(fileURL: URL) async throws -> Publication
}

/// Resolves a Book's on-disk file URL → Readium `Publication` via the
/// 3.9 `AssetRetriever` + `PublicationOpener` + `DefaultPublicationParser`
/// pipeline (Spike A locked this exact shape).
///
/// **Sendability:** Marked `final class @unchecked Sendable` (not `actor`),
/// mirroring the Phase 5 `PDFReaderViewModel` pattern for non-Sendable
/// Readium types. The plan source called for an `actor`, but Swift 6 strict
/// concurrency forbids two things that pattern requires:
/// (1) sending stored non-Sendable `AssetRetriever`/`PublicationOpener`
/// references to their own nonisolated methods from `self`-isolated context,
/// and (2) returning the non-Sendable `Publication` from an actor-isolated
/// method to a nonisolated caller. The pipeline is built fresh per call,
/// so the loader holds no mutable cross-call state and the Sendable
/// override is sound.
public final class EPUBPublicationLoader: EPUBPublicationLoading, @unchecked Sendable {

    public init() {}

    /// Opens the EPUB at `fileURL`. Throws on any failure in the
    /// retrieve → open pipeline.
    ///
    /// Per Phase 19 plan 19-09 (F-P0-08 EPUB slice): this body runs
    /// off-main when called from ``EPUBReaderViewModel/load()`` because
    /// the view-model wraps the invocation in `Task.detached(priority:
    /// .userInitiated)`. The Readium `AssetRetriever.retrieve` and
    /// `PublicationOpener.open` calls are themselves `async` and
    /// nonisolated, so the awaited continuation also resumes off-main —
    /// the multi-second EPUB ZIP unpack never touches the main draw
    /// loop.
    public func open(fileURL: URL) async throws -> Publication {
        guard let readiumFileURL = FileURL(url: fileURL) else {
            throw EPUBPublicationLoaderError.invalidFileURL(fileURL)
        }

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

        let asset: Asset
        do {
            asset = try await assetRetriever.retrieve(url: readiumFileURL).get()
        } catch {
            Log.reader.error("AssetRetriever failed for \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw EPUBPublicationLoaderError.assetRetrievalFailed(error.localizedDescription)
        }

        do {
            return try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
        } catch {
            Log.reader.error("PublicationOpener failed for \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw EPUBPublicationLoaderError.publicationOpenFailed(error.localizedDescription)
        }
    }
}
