import CryptoKit
import Foundation

struct BookFingerprintService: Sendable {
    struct SelectedSource: Sendable {
        let sha256: String
        let byteCount: Int64
        let metadata: BookMetadata
        let version: ManagedFileVersion
    }

    private let rootURL: URL
    private let bookStore: any BookStore
    private let persistence: (any BookFingerprintPersistence)?
    private let versionInspector: any ManagedFileVersionInspecting
    private let isTombstoned: (@Sendable (BookID) async -> Bool)?
    private let currentGeneration: @Sendable () async -> UInt64?
    private let isRetired: (@Sendable (Book, UInt64) async -> Bool)?
    private let isSourceAvailable: (@Sendable (Book) async -> Bool)?
    private let hashFile: @Sendable (URL) throws -> String
    private let sourceProbe: CoordinatedSourceProbe

    init(
        rootURL: URL,
        bookStore: any BookStore,
        persistence: (any BookFingerprintPersistence)? = nil,
        versionInspector: any ManagedFileVersionInspecting = FileManagedFileVersionInspector(),
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil,
        currentGeneration: @escaping @Sendable () async -> UInt64? = { nil },
        isRetired: (@Sendable (Book, UInt64) async -> Bool)? = nil,
        isSourceAvailable: (@Sendable (Book) async -> Bool)? = nil,
        hashFile: @escaping @Sendable (URL) throws -> String = { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256Accumulator()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data) }
            return hasher.finalize()
        }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.bookStore = bookStore
        self.persistence = persistence
        self.versionInspector = versionInspector
        self.isTombstoned = isTombstoned
        self.currentGeneration = currentGeneration
        self.isRetired = isRetired
        self.isSourceAvailable = isSourceAvailable
        self.hashFile = hashFile
        self.sourceProbe = CoordinatedSourceProbe()
    }

    func probeSelectedSource(at sourceURL: URL, metadataExtractor: (any MetadataExtractor)?) async throws -> SelectedSource {
        let result = try await sourceProbe.probe(sourceURL, metadataExtractor: metadataExtractor, hashFile: hashFile)
        return SelectedSource(sha256: result.sha256, byteCount: result.byteCount, metadata: result.metadata, version: result.version)
    }

    func matchingCandidate(ownerID: UserID, byteCount: Int64, sha256: String) async throws -> BookImportCandidateSnapshot? {
        let capturedGeneration = await currentGeneration()
        var sawRetiredMatch = false
        var sawUnavailableMatch = false
        let books = try await bookStore.books(for: ownerID)
        for book in books {
            guard book.userId == ownerID,
                  await isTombstoned?(book.id) != true,
                  let url = managedURL(for: book),
                  FileManager.default.fileExists(atPath: url.path) else { continue }

            let stored: BookFileFingerprint?
            if let persistence {
                stored = try? await persistence.fingerprint(bookID: book.id, ownerID: ownerID)
            } else {
                stored = nil
            }
            let pending: PendingBookMaterialization?
            if let persistence {
                do {
                    pending = try await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID)
                } catch {
                    continue
                }
            } else {
                pending = nil
            }
            if let pending {
                guard pending.phase == .ready,
                      pending.expectedSHA256.caseInsensitiveCompare(sha256) == .orderedSame,
                      pending.expectedByteCount == byteCount,
                      pending.destinationRelativePath == book.fileURL else { continue }
            }
            let revision = pending?.promotionRevision
                ?? stored?.version.materializationRevision
                ?? UUID()
            guard let observed = try versionInspector.managedFileVersion(at: url, materializationRevision: revision),
                  observed.byteCount == byteCount else { continue }
            if let pending {
                guard pending.destinationFileIdentifier == observed.fileIdentifier,
                      pending.promotionRevision == observed.materializationRevision else { continue }
            }

            let digest: String
            var actualVersion = observed
            if let fingerprint = stored,
               fingerprint.bookID == book.id,
               fingerprint.ownerID == ownerID,
               fingerprint.sha256.count == 64,
               fingerprint.version == observed {
                digest = fingerprint.sha256
            } else {
                do {
                    let hashed = try await sourceProbe.probe(url, materializationRevision: actualVersion.materializationRevision, hashFile: hashFile)
                    guard hashed.byteCount == byteCount,
                          hashed.version == actualVersion else { continue }
                    actualVersion = hashed.version
                    digest = hashed.sha256
                } catch {
                    continue
                }
                guard try versionInspector.managedFileVersion(at: url, materializationRevision: actualVersion.materializationRevision) == actualVersion else { continue }
                if let persistence {
                    let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: ownerID, sha256: digest, version: actualVersion)
                    guard let capturedGeneration,
                          (try? await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: capturedGeneration, expectedRelativePath: book.fileURL, expectedVersion: actualVersion)) == true else { continue }
                }
            }

            guard digest.caseInsensitiveCompare(sha256) == .orderedSame,
                  let current = try await bookStore.book(book.id),
                  current.userId == ownerID, current.fileURL == book.fileURL,
                  await isTombstoned?(book.id) != true,
                  try versionInspector.managedFileVersion(at: url, materializationRevision: actualVersion.materializationRevision) == actualVersion else { continue }
            guard await currentGeneration() == capturedGeneration else { throw BookFileStorage.StorageError.sourceUnreadable }
            if let generation = capturedGeneration, await isRetired?(current, generation) == true {
                sawRetiredMatch = true
                continue
            }
            if let isSourceAvailable, !(await isSourceAvailable(current)) {
                if let generation = capturedGeneration, await isRetired?(current, generation) == true { sawRetiredMatch = true }
                else { sawUnavailableMatch = true }
                continue
            }
            guard await currentGeneration() == capturedGeneration,
                  let latest = try await bookStore.book(book.id), latest == current,
                  await isTombstoned?(book.id) != true,
                  try versionInspector.managedFileVersion(at: url, materializationRevision: actualVersion.materializationRevision) == actualVersion else {
                throw BookFileStorage.StorageError.sourceUnreadable
            }
            if let generation = capturedGeneration, await isRetired?(current, generation) == true {
                sawRetiredMatch = true
                continue
            }
            return BookImportCandidateSnapshot(
                bookID: book.id,
                ownerID: ownerID,
                relativePath: book.fileURL,
                sha256: digest.lowercased(),
                fingerprintRevision: actualVersion.materializationRevision,
                observedManagedVersion: actualVersion,
                absoluteURL: url
            )
        }
        if sawRetiredMatch { throw BookImportFailure.deletionInProgress }
        if sawUnavailableMatch { throw BookFileStorage.StorageError.sourceUnreadable }
        return nil
    }

    func copySelectedSource(at sourceURL: URL, to stagingURL: URL, selected: SelectedSource) async throws {
        try await sourceProbe.copyVerifiedSource(
            sourceURL,
            to: stagingURL,
            expected: CoordinatedSourceProbe.Result(
                sha256: selected.sha256,
                byteCount: selected.byteCount,
                version: selected.version,
                metadata: selected.metadata
            ),
            hashFile: hashFile
        )
    }

    func matchingBook(ownerID: UserID, byteCount: Int64, sha256: String) async throws -> Book? {
        guard let candidate = try await matchingCandidate(ownerID: ownerID, byteCount: byteCount, sha256: sha256) else { return nil }
        return try await bookStore.book(candidate.bookID)
    }

    func verifyAndCacheManagedFile(for book: Book, expectedSHA256: String? = nil, expectedByteCount: Int64? = nil) async -> VerifiedManagedFile? {
        let capturedGeneration = await currentGeneration()
        guard let url = managedURL(for: book), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let pending: PendingBookMaterialization?
            if let persistence {
                pending = try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)
            } else {
                pending = nil
            }
            if let pending {
                guard pending.phase == .ready,
                      pending.destinationRelativePath == book.fileURL,
                      pending.expectedByteCount >= 0,
                      pending.promotionRevision != nil else { return nil }
            }
            let priorFingerprint: BookFileFingerprint?
            if pending == nil, let persistence {
                priorFingerprint = try await persistence.fingerprint(bookID: book.id, ownerID: book.userId)
            } else {
                priorFingerprint = nil
            }
            let probeRevision = pending?.promotionRevision
                ?? priorFingerprint?.version.materializationRevision
                ?? UUID()
            let probed = try await sourceProbe.probe(url, materializationRevision: probeRevision, hashFile: hashFile)
            // Re-seeding an unchanged legacy managed file must preserve the
            // content revision already carried by open reader leases. A new
            // revision is warranted only when verified bytes or filesystem
            // identity changed (or a ready materialization provides its own
            // promotion revision).
            let revision = if let pending {
                pending.promotionRevision ?? probed.version.materializationRevision
            } else if let priorFingerprint,
                      priorFingerprint.sha256.caseInsensitiveCompare(probed.sha256) == .orderedSame,
                      priorFingerprint.version.byteCount == probed.version.byteCount,
                      priorFingerprint.version.modificationDate == probed.version.modificationDate,
                      priorFingerprint.version.fileIdentifier == probed.version.fileIdentifier {
                priorFingerprint.version.materializationRevision
            } else if priorFingerprint != nil {
                UUID()
            } else {
                probed.version.materializationRevision
            }
            let result = CoordinatedSourceProbe.Result(
                sha256: probed.sha256,
                byteCount: probed.byteCount,
                version: ManagedFileVersion(
                    byteCount: probed.version.byteCount,
                    modificationDate: probed.version.modificationDate,
                    fileIdentifier: probed.version.fileIdentifier,
                    materializationRevision: revision
                ),
                metadata: probed.metadata
            )
            guard expectedSHA256.map({ result.sha256.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
                  expectedByteCount.map({ result.byteCount == $0 }) ?? true,
                  try versionInspector.managedFileVersion(at: url, materializationRevision: result.version.materializationRevision) == result.version else { return nil }
            if let pending {
                guard pending.expectedSHA256.caseInsensitiveCompare(result.sha256) == .orderedSame,
                      pending.expectedByteCount == result.byteCount,
                      pending.destinationFileIdentifier == result.version.fileIdentifier,
                      pending.promotionRevision == result.version.materializationRevision else { return nil }
            }
            let acceptance = priorFingerprint.flatMap { prior in
                prior.sha256.caseInsensitiveCompare(result.sha256) == .orderedSame
                    ? prior.serverAcceptance
                    : nil
            }
            let fingerprint = BookFileFingerprint(
                bookID: book.id,
                ownerID: book.userId,
                sha256: result.sha256,
                version: result.version,
                serverAcceptance: acceptance
            )
            var persisted = false
            if let persistence {
                if let capturedGeneration {
                    persisted = (try? await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: capturedGeneration, expectedRelativePath: book.fileURL, expectedVersion: result.version)) == true
                }
            }
            return VerifiedManagedFile(fingerprint: fingerprint, fingerprintPersisted: persisted)
        } catch {
            Log.event("library.import.fingerprint.seed_failed", level: .info, data: ["book_id": book.id.uuidString, "error": String(describing: error)])
            return nil
        }
    }

    private func managedURL(for book: Book) -> URL? {
        let url = rootURL.appendingPathComponent(book.fileURL).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix) else { return nil }
        return url
    }
}

private struct SHA256Accumulator {
    private var hasher = CryptoKit.SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    mutating func finalize() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
