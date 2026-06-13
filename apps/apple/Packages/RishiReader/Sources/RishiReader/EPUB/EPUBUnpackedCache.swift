import Foundation
import ReadiumZIPFoundation
import RishiCore
import RishiLogging

/// Phase 21 Plan 21-04 — persistent on-disk cache of unpacked EPUBs.
///
/// PDF cold-opens stay fast across restarts because `PDFThumbnailCache`
/// writes JPGs to `<systemCaches>/PDFThumbnails/<bookId>/` and they
/// survive process death. EPUBs do not — Readium's `AssetRetriever`
/// unpacks the ZIP into a per-process area that disappears between
/// launches. This cache plugs the gap: once an EPUB has been opened
/// successfully, its unpacked tree lives under
/// `<systemCaches>/EPUBUnpacked/<bookId>/` with a `<bookId>.mtime`
/// sidecar gating freshness (rebuilt if the source ZIP's mtime changes).
///
/// `EPUBPublicationLoader` consults this cache first; on hit it opens
/// a directory asset (no unpack); on miss it unpacks then opens; on
/// unpack failure it falls back to the legacy ZIP-asset path so the
/// reader never breaks on cache failures.
///
/// **ZIP backend:** Readium 3.9 transitively ships a fork of
/// `ZIPFoundation` (module `ReadiumZIPFoundation`) via `ReadiumShared`.
/// Importing it directly avoids adding a new top-level SwiftPM
/// dependency, satisfying the apps/apple CLAUDE.md durable constraint
/// against engine swaps + new deps.
public actor EPUBUnpackedCache {

    public struct Configuration: Sendable {
        public var rootDirectory: URL

        public init(rootDirectory: URL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EPUBUnpacked", isDirectory: true)
        ) {
            self.rootDirectory = rootDirectory
        }
    }

    private let config: Configuration
    private let fileManager: FileManager
    /// Test-only counter: number of physical unpack operations performed.
    /// Exposed as actor-isolated so concurrent reads from the parallel-
    /// unpack tests see a coherent value.
    public private(set) var didUnpackCount: Int = 0
    /// Per-bookId in-flight unpack task — coalesces concurrent callers
    /// so two parallel `unpackIfNeeded` calls do one unzip, not two.
    private var inflight: [BookID: Task<URL?, Never>] = [:]

    public init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) {
        self.config = configuration
        self.fileManager = fileManager
    }

    // MARK: - Nonisolated fast path

    /// Returns the unpacked directory URL if a warm cache exists for this
    /// `bookId` AND the source ZIP's mtime matches the sidecar. Returns
    /// nil otherwise. Mirrors `CoverCache.cachedURLIfFresh` — a synchronous
    /// stat-only path that callers (here: `EPUBPublicationLoader.open`)
    /// take before paying the actor hop for `unpackIfNeeded`.
    ///
    /// Safe to call from any isolation domain; uses only `FileManager.default`
    /// (documented thread-safe) and read-only configuration captured at init.
    public nonisolated func unpackedDirectoryIfFresh(
        for bookId: BookID,
        sourceFileURL: URL
    ) -> URL? {
        let dir = unpackedDirectoryURL(for: bookId)
        let sidecar = mtimeSidecarURL(for: bookId)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue,
              let cachedMtime = Self.readMtimeNonisolated(at: sidecar),
              let currentMtime = Self.sourceMtimeNonisolated(at: sourceFileURL, fileManager: fm),
              Self.mtimesAreEqual(cachedMtime, currentMtime)
        else { return nil }
        return dir
    }

    // MARK: - Slow path (unpack on miss)

    /// On cache hit, returns the unpacked directory URL immediately.
    /// On miss/stale, unpacks the ZIP into the cache directory, writes
    /// the mtime sidecar, and returns the directory URL. Returns nil on
    /// unpack failure — caller MUST fall back to the original ZIP-asset
    /// path so the reader never breaks on cache failures.
    public func unpackIfNeeded(
        for bookId: BookID,
        sourceFileURL: URL
    ) async -> URL? {
        if let hit = unpackedDirectoryIfFresh(for: bookId, sourceFileURL: sourceFileURL) {
            return hit
        }
        // Coalesce concurrent unpack requests for the same book.
        if let existing = inflight[bookId] {
            return await existing.value
        }
        // KEEP: actor-method await; the actor already retains this task
        // in `inflight[bookId]`, so a weak-self capture would orphan the
        // in-flight unzip if the actor briefly released. Strong capture
        // is the safe, canonical choice — the task is removed from
        // `inflight` immediately after `task.value` returns, so the
        // strong reference does not extend the actor's lifetime.
        let task = Task { [self] () async -> URL? in
            await self.performUnpack(bookId: bookId, sourceFileURL: sourceFileURL)
        }
        inflight[bookId] = task
        let result = await task.value
        inflight[bookId] = nil
        return result
    }

    /// Drop the unpacked directory + sidecar for `bookId`. Called when a
    /// book is removed from the library or when a phase-level invalidate
    /// hook fires.
    ///
    /// Reentrancy: `performUnpack` suspends across
    /// `await FileManager.default.unzipItem(...)`. The actor unlocks at
    /// that suspend point, so a concurrent `clear(for:)` could otherwise
    /// race the unzip and delete the destination mid-write, leaving a
    /// half-unpacked tree with a stale mtime sidecar. To close the
    /// window we cancel the in-flight task first, await its completion
    /// (which will observe the cancellation between the mkdir and the
    /// unzip), and only then remove files. The unpack task itself
    /// cleans up its partial directory on its own cancellation/error
    /// branches, so the subsequent removeItem calls are idempotent.
    public func clear(for bookId: BookID) async {
        if let task = inflight[bookId] {
            task.cancel()
            inflight[bookId] = nil
            _ = await task.value
        }
        let dir = unpackedDirectoryURL(for: bookId)
        let sidecar = mtimeSidecarURL(for: bookId)
        try? fileManager.removeItem(at: dir)
        try? fileManager.removeItem(at: sidecar)
    }

    // MARK: - Internals

    private func performUnpack(bookId: BookID, sourceFileURL: URL) async -> URL? {
        let dir = unpackedDirectoryURL(for: bookId)

        // Ensure the root directory (parent of <bookId>/) exists.
        do {
            try fileManager.createDirectory(
                at: config.rootDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Log.reader.error(
                "EPUBUnpackedCache mkdir root failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        // Drop any stale partial directory before unpacking — half-unpacked
        // trees would otherwise be presented to Readium as a "warm" cache
        // and break the open. unzipItem demands the destination not exist
        // (or be empty); a previous failed unpack would have left junk.
        try? fileManager.removeItem(at: dir)

        // Cooperative cancellation gate between mkdir and the multi-second
        // unzip — a concurrent `clear(for:)` cancels this task, and we
        // bail BEFORE asking unzipItem to write into a directory the
        // caller is about to remove.
        if Task.isCancelled { return nil }

        do {
            // ReadiumZIPFoundation's unzipItem is an `async throws` extension
            // on FileManager. We invoke it on FileManager.default (documented
            // Sendable) instead of `self.fileManager` so Swift 6 strict
            // concurrency does not flag sending the actor-isolated stored
            // FileManager across the nonisolated async boundary.
            try await FileManager.default.unzipItem(at: sourceFileURL, to: dir)
        } catch {
            Log.reader.error(
                "EPUBUnpackedCache unzip failed: \(error.localizedDescription, privacy: .public)"
            )
            // Clean up partial output so the next attempt starts from a
            // known-empty state.
            try? fileManager.removeItem(at: dir)
            return nil
        }

        // Second cancellation gate — if `clear(for:)` raced us between
        // the mkdir gate and now, do not publish the sidecar (clear is
        // about to drop the directory anyway). Skipping the sidecar
        // write keeps the on-disk state coherent: either the directory
        // AND sidecar both exist (warm hit) or both are missing (cold),
        // never sidecar-without-directory.
        if Task.isCancelled {
            try? fileManager.removeItem(at: dir)
            return nil
        }

        // Write mtime sidecar — read the source mtime AFTER unpack so we
        // can't accidentally race a writer that's still touching the file.
        if let mtime = sourceMtime(at: sourceFileURL) {
            let text = String(mtime.timeIntervalSince1970)
            try? Data(text.utf8).write(to: mtimeSidecarURL(for: bookId), options: .atomic)
        }
        didUnpackCount &+= 1
        return dir
    }

    private nonisolated func unpackedDirectoryURL(for bookId: BookID) -> URL {
        config.rootDirectory.appendingPathComponent(bookId.uuidString, isDirectory: true)
    }

    private nonisolated func mtimeSidecarURL(for bookId: BookID) -> URL {
        config.rootDirectory.appendingPathComponent("\(bookId.uuidString).mtime")
    }

    private static func readMtimeNonisolated(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let interval = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private static func sourceMtimeNonisolated(at url: URL, fileManager: FileManager) -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func sourceMtime(at url: URL) -> Date? {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// 1ms tolerance for Date round-trip drift via `String(timeIntervalSince1970)`,
    /// matching `CoverCache.mtimesAreEqual` so behaviour is consistent across
    /// the two on-disk caches.
    private static func mtimesAreEqual(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 0.001
    }
}
