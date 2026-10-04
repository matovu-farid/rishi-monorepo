import CryptoKit
import Foundation

/// Re-adopts interrupted imports only after the prior account generation has
/// been fenced and drained. The caller must pass the identity and generation
/// that its authenticated session currently owns.
public struct BookImportRecovery: Sendable {
    private enum ArtifactVerification {
        case verified(VerifiedBookArtifacts)
        case invalid
        case retryable
    }

    public enum RecoveryError: Error, Sendable, Equatable {
        case retryableWorkRemains
    }
    private let rootURL: URL
    private let bookStore: any BookStore
    private let persistence: any BookImportPersistence
    private let lifecycle: BookImportLifecycle
    private let fileVersionInspector: any ManagedFileVersionInspecting
    private let resumeRecovered: @Sendable (Book, BookMaterializationToken) async throws -> Void
    private let prepareOwnedSourceCleanup: (@Sendable (BookMaterializationToken) async -> Bool)?

    public init(
        rootURL: URL,
        bookStore: any BookStore,
        persistence: any BookImportPersistence,
        lifecycle: BookImportLifecycle,
        fileVersionInspector: any ManagedFileVersionInspecting = FileManagedFileVersionInspector(),
        prepareOwnedSourceCleanup: (@Sendable (BookMaterializationToken) async -> Bool)? = nil,
        resume: @escaping @Sendable (Book, BookMaterializationToken) async throws -> Void = { _, _ in }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.bookStore = bookStore
        self.persistence = persistence
        self.lifecycle = lifecycle
        self.fileVersionInspector = fileVersionInspector
        self.prepareOwnedSourceCleanup = prepareOwnedSourceCleanup
        self.resumeRecovered = resume
    }

    /// Returns fresh attempt tokens for verified jobs. Jobs owned by another
    /// user, with incomplete provenance, or with changed artifacts are left
    /// untouched for the normal retry or quarantine path.
    public func recover(
        ownerID: UserID,
        generation: UInt64,
        isCurrentIdentity: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) async throws -> [BookMaterializationToken] {
        let ownedBooks = try await bookStore.books(for: ownerID).filter { $0.userId == ownerID }
        await cleanupReadyOwnedSources(books: ownedBooks, ownerID: ownerID, generation: generation)
        var candidates: [BookID: BookMaterializationToken] = [:]
        var recoveryClaims: [BookID: BookImportRecoveryClaim] = [:]
        var hasRetryableWork = false
        guard await isCurrentIdentity() else { return [] }
        for book in ownedBooks {
            guard let job = try await persistence.pendingMaterializationForRecovery(
                bookID: book.id,
                ownerID: ownerID,
                currentGeneration: generation
            ),
                  job.token.ownerID == ownerID,
                  job.token.bookID == book.id,
                  job.phase != .ready,
                  job.phase != .failed,
                  job.phase != .cancelled else { continue }
            if Self.isWaitingForPicker(job) {
                guard let currentToken = try await persistence.reauthorizeWaitingRecovery(
                    expectedToken: job.token,
                    currentOwnerID: ownerID,
                    currentGeneration: generation
                ), currentToken.ownerID == ownerID,
                   currentToken.accountGeneration == generation,
                   currentToken.bookID == book.id,
                   currentToken.attemptID == job.token.attemptID else {
                    hasRetryableWork = true
                    continue
                }
                continue
            }
            guard let claim = lifecycle.claimBookRecovery(ownerID: ownerID, generation: generation, bookID: book.id) else {
                // A live materialization or another recovery owns this book;
                // leave it alone so this scan cannot retire user work, and
                // keep recovery incomplete for a later scan.
                hasRetryableWork = true
                continue
            }
            candidates[book.id] = job.token
            recoveryClaims[book.id] = claim
        }

        // Ordinary service resolution has no recovery work to perform. In
        // particular, do not fence owner admission or disturb live readers.
        guard !candidates.isEmpty else {
            if hasRetryableWork { throw RecoveryError.retryableWorkRemains }
            return []
        }
        for (bookID, token) in candidates.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            await lifecycle.drainBook(ownerID: ownerID, generation: token.accountGeneration, bookID: bookID)
        }
        guard await isCurrentIdentity() else { return [] }

        var recovered: [BookMaterializationToken] = []
        for (bookID, expectedToken) in candidates.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let recoveryClaim = recoveryClaims[bookID] else { continue }
            defer { recoveryClaim.release() }
            guard let book = try await bookStore.book(bookID), book.userId == ownerID,
                  let job = try await persistence.pendingMaterializationForRecovery(
                    bookID: bookID,
                    ownerID: ownerID,
                    currentGeneration: generation
                  ),
                  job.token == expectedToken,
                  job.token.ownerID == ownerID,
                  job.token.bookID == bookID,
                  job.phase != .ready,
                  job.phase != .failed,
                  job.phase != .cancelled,
                  !Self.isWaitingForPicker(job) else { continue }
            guard await isCurrentIdentity() else { return recovered }
            let artifacts: VerifiedBookArtifacts
            switch verify(job: job) {
            case let .verified(value): artifacts = value
            case .retryable:
                hasRetryableWork = true
                continue
            case .invalid:
                let retiredStagingPath = job.stagingRelativePath
                let quarantined = try await persistence.quarantineRecovery(
                    expectedToken: job.token,
                    currentOwnerID: ownerID,
                    currentGeneration: generation,
                    newAttemptID: UUID()
                )
                if let quarantined,
                   quarantined.ownerID == ownerID,
                   quarantined.accountGeneration == generation,
                   quarantined.bookID == bookID {
                    Self.removeRetiredPartialIfSafe(
                        relativePath: retiredStagingPath,
                        retiredAttemptID: expectedToken.attemptID,
                        rootURL: rootURL
                    )
                    _ = lifecycle.activatePromotionAttempt(quarantined)
                } else {
                    hasRetryableWork = true
                }
                // A successful quarantine is durable and authorizes picker
                // retry; later scans skip its persisted waiting-for-picker
                // state instead of rotating it indefinitely.
                continue
            }
            let retiredStagingPath = job.stagingRelativePath
            let retiredAttemptWasUnprepared = [.registered, .copying, .paused].contains(job.phase)
                && job.preparedFileIdentifier == nil
                && job.destinationFileIdentifier == nil
                && job.promotionRevision == nil
            let attemptID = UUID()
            guard let token = try await persistence.adoptRecovery(
                expectedToken: job.token,
                currentOwnerID: ownerID,
                currentGeneration: generation,
                newAttemptID: attemptID,
                verifiedArtifacts: artifacts
            ), token.ownerID == ownerID, token.accountGeneration == generation,
               token.bookID == bookID, token.attemptID == attemptID else {
                if job.phase != .paused {
                    _ = try? await persistence.transition(token: job.token, from: job.phase, to: .paused)
                }
                continue
            }
            if retiredAttemptWasUnprepared {
                Self.removeRetiredPartialIfSafe(
                    relativePath: retiredStagingPath,
                    retiredAttemptID: expectedToken.attemptID,
                    rootURL: rootURL
                )
            }
            guard lifecycle.activatePromotionAttempt(token) else { continue }
            guard let activeAttempt = recoveryClaim.promoteMaterialization(token) else {
                hasRetryableWork = true
                continue
            }
            defer { activeAttempt.release() }
            guard await isCurrentIdentity() else {
                await pauseAdoptedAttempt(token)
                return recovered
            }
            var resumed = false
            do {
                try await resumeRecovered(book, token)
                resumed = true
                await cleanupReadyOwnedSources(books: [book], ownerID: ownerID, generation: generation)
            } catch {
                await pauseAdoptedAttempt(token)
                await lifecycle.failPendingBookSource(
                    ownerID: token.ownerID,
                    generation: token.accountGeneration,
                    bookID: token.bookID
                )
                hasRetryableWork = true
            }
            if resumed { recovered.append(token) }
        }
        if hasRetryableWork { throw RecoveryError.retryableWorkRemains }
        return recovered
    }

    private func cleanupReadyOwnedSources(books: [Book], ownerID: UserID, generation: UInt64) async {
        guard let prepareOwnedSourceCleanup else { return }
        let importsURL = rootURL.appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
        for book in books where book.userId == ownerID {
            guard let job = try? await persistence.pendingMaterializationForRecovery(
                bookID: book.id,
                ownerID: ownerID,
                currentGeneration: generation
            ), job.phase == .ready, case .ownedStaging = job.sourceKind,
               let relative = job.ownedSourceRelativePath,
               let fingerprint = try? await persistence.fingerprint(bookID: book.id, ownerID: ownerID),
               fingerprint.bookID == book.id,
               fingerprint.ownerID == ownerID,
               fingerprint.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame,
               fingerprint.version.fileIdentifier == job.destinationFileIdentifier,
               fingerprint.version.materializationRevision == job.promotionRevision,
               let sourceURL = Self.containedURL(relative, rootURL: rootURL) else { continue }
            let components = relative.split(separator: "/")
            guard components.count == 3,
                  components[0] == "Imports",
                  UUID(uuidString: String(components[1])) != nil,
                  components[2].hasPrefix("source."),
                  String(components[2].dropFirst("source.".count)).lowercased() == book.formatType.rawValue.lowercased() else { continue }
            let attemptDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
            let destinationURL = rootURL.appendingPathComponent(book.fileURL).standardizedFileURL
            guard attemptDirectory.deletingLastPathComponent() == importsURL,
                  sourceURL.deletingLastPathComponent() == attemptDirectory,
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  FileManager.default.fileExists(atPath: destinationURL.path),
                  let destinationProbe = try? await CoordinatedSourceProbe().probe(
                    destinationURL,
                    materializationRevision: fingerprint.version.materializationRevision
                  ),
                  destinationProbe.version == fingerprint.version,
                  destinationProbe.byteCount == fingerprint.version.byteCount,
                  destinationProbe.sha256.caseInsensitiveCompare(fingerprint.sha256) == .orderedSame,
                  await prepareOwnedSourceCleanup(job.token) else { continue }
            try? FileManager.default.removeItem(at: attemptDirectory)
        }
    }

    private func pauseAdoptedAttempt(_ token: BookMaterializationToken) async {
        guard let pending = try? await persistence.pendingMaterialization(bookID: token.bookID, ownerID: token.ownerID),
              pending.token == token,
              pending.phase != .ready,
              pending.phase != .failed,
              pending.phase != .cancelled else { return }
        _ = try? await persistence.transition(token: token, from: pending.phase, to: .paused)
    }

    private func verify(job: PendingBookMaterialization) -> ArtifactVerification {
        guard job.expectedByteCount >= 0 else { return .invalid }
        if [.registered, .copying, .paused].contains(job.phase), job.preparedFileIdentifier == nil,
           job.destinationFileIdentifier == nil, job.promotionRevision == nil {
            return .verified(VerifiedBookArtifacts(
                sha256: job.expectedSHA256.lowercased(),
                byteCount: job.expectedByteCount,
                stagingRelativePath: job.stagingRelativePath,
                destinationRelativePath: job.destinationRelativePath,
                preparedFileIdentifier: nil,
                destinationFileIdentifier: nil,
                promotionRevision: nil
            ))
        }
        guard let preparedID = job.preparedFileIdentifier,
              !preparedID.isEmpty,
              let stagingURL = Self.containedURL(job.stagingRelativePath, rootURL: rootURL) else { return .invalid }

        var transientFailure = false
        var stagedDigest: (sha256: String, count: Int64)?
        do {
            if let stagedVersion = try fileVersionInspector.managedFileVersion(at: stagingURL, materializationRevision: job.sourceVersion.materializationRevision) {
                if stagedVersion.byteCount == job.expectedByteCount,
                   stagedVersion.fileIdentifier == preparedID {
                    do {
                        let digest = try Self.digestAndCount(stagingURL)
                        if digest.count == job.expectedByteCount,
                           digest.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame {
                            stagedDigest = digest
                        }
                    } catch {
                        transientFailure = true
                    }
                }
            }
        } catch {
            transientFailure = true
        }

        var destinationIdentifier: String?
        var destinationDigest: (sha256: String, count: Int64)?
        let destinationExpectedID = job.destinationFileIdentifier
            ?? ((job.phase == .promoting || (job.phase == .paused && job.promotionRevision != nil)) ? preparedID : nil)
        if let expectedID = destinationExpectedID,
           let promotionRevision = job.promotionRevision,
           let destinationURL = Self.containedURL(job.destinationRelativePath, rootURL: rootURL) {
            do {
                if let version = try fileVersionInspector.managedFileVersion(at: destinationURL, materializationRevision: promotionRevision) {
                    if version.byteCount == job.expectedByteCount,
                       version.fileIdentifier == expectedID,
                       version.materializationRevision == promotionRevision {
                        do {
                            let digest = try Self.digestAndCount(destinationURL)
                            if digest.count == job.expectedByteCount,
                               digest.sha256.caseInsensitiveCompare(job.expectedSHA256) == .orderedSame {
                                destinationIdentifier = expectedID
                                destinationDigest = digest
                            }
                        } catch {
                            transientFailure = true
                        }
                    }
                }
            } catch {
                transientFailure = true
            }
        }

        if job.phase == .prepared, stagedDigest == nil { return transientFailure ? .retryable : .invalid }
        if job.phase == .promoted, destinationDigest == nil { return transientFailure ? .retryable : .invalid }
        if job.phase == .promoting, stagedDigest == nil && destinationDigest == nil { return transientFailure ? .retryable : .invalid }
        if job.phase == .paused, stagedDigest == nil && destinationDigest == nil { return transientFailure ? .retryable : .invalid }
        guard let verifiedDigest = stagedDigest ?? destinationDigest else { return transientFailure ? .retryable : .invalid }

        return .verified(VerifiedBookArtifacts(
            sha256: verifiedDigest.sha256.lowercased(),
            byteCount: verifiedDigest.count,
            stagingRelativePath: job.stagingRelativePath,
            destinationRelativePath: job.destinationRelativePath,
            preparedFileIdentifier: preparedID,
            destinationFileIdentifier: job.destinationFileIdentifier,
            promotionRevision: job.promotionRevision
        ))
    }

    private static func isWaitingForPicker(_ job: PendingBookMaterialization) -> Bool {
        job.phase == .paused
            && (job.retryableErrorCode == "recovery_artifact_invalid"
                || job.retryableErrorCode == "recovery_source_unavailable")
    }

    private static func containedURL(_ relativePath: String, rootURL: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix) else { return nil }
        return url
    }

    private static func removeRetiredPartialIfSafe(relativePath: String, retiredAttemptID: UUID, rootURL: URL) {
        let expectedPath = "Imports/\(retiredAttemptID.uuidString)/content.partial"
        guard relativePath == expectedPath,
              let url = containedURL(relativePath, rootURL: rootURL),
              FileManager.default.fileExists(atPath: url.path) else { return }
        // Recovery drains the previous book attempt before adoption. The
        // UUID-derived path is that attempt's only staging file, so remove
        // only the partial file and preserve directories and destination.
        try? FileManager.default.removeItem(at: url)
    }

    private static func digestAndCount(_ url: URL) throws -> (sha256: String, count: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
            count += Int64(data.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
