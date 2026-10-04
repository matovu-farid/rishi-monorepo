import CryptoKit
import Foundation
import Testing
@testable import rishi

@Suite("Book materialization copy")
struct BookMaterializationTests {
    @Test("a staged copy with a digest mismatch is rejected and removed")
    func rejectsCorruptedStagedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = root.appendingPathComponent("provider/book.epub")
        let stagingURL = root.appendingPathComponent("Imports/attempt/content.partial")
        let bytes = Data("verified source bytes".utf8)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
        let permit = BookSourceAccessPermit()
        let authority = BookSourceEffectAuthority()
        authority.register(permit)
        let owner = try BookSourceOwner(
            url: sourceURL,
            access: .localPreview,
            sourceAccessPermit: permit,
            effectAuthority: authority
        )
        let source = BookSourceLease(owner: owner, cachePolicy: .transient)
        let incorrectDigest = SHA256.hash(data: Data("different content".utf8)).map { String(format: "%02x", $0) }.joined()

        await #expect(throws: CoordinatedBookCopier.CopyError.contentMismatch) {
            try await CoordinatedBookCopier().copy(
                source: source,
                to: stagingURL,
                expectedSHA256: incorrectDigest,
                expectedByteCount: Int64(bytes.count),
                sourceVersion: sourceVersion
            )
        }
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test("promotion retirement cancels waiters and drains the admitted promoter")
    func promotionRetirementDrainsWithoutHoldingTheGate() async throws {
        let ownerID = UUID()
        let bookID = UUID()
        let registry = BookSourceRegistry(currentGeneration: { 7 }, currentOwnerID: { ownerID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry)
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: 7, bookID: bookID, attemptID: UUID())
        let gate = MaterializationTestGate()
        let drainProbe = MaterializationDrainProbe()

        let admitted = Task {
            try await lifecycle.withPromotionPermit(token: token) {
                await gate.waitUntilReleased()
            }
        }
        await gate.waitUntilEntered()
        let waiter = Task {
            try await lifecycle.withPromotionPermit(token: token) {}
        }
        await Task.yield()
        lifecycle.retireBook(ownerID: ownerID, generation: 7, bookID: bookID)
        let drain = Task {
            await lifecycle.drainBook(ownerID: ownerID, generation: 7, bookID: bookID)
            await drainProbe.markComplete()
        }

        await #expect(throws: BookImportPromotionError.retired) { try await waiter.value }
        #expect(!(await drainProbe.isComplete()))
        await gate.release()
        try await admitted.value
        await drain.value
        #expect(await drainProbe.isComplete())
    }

    @Test("coordinator only publishes a book after staged verification and atomic promotion")
    func coordinatorPublishesVerifiedMaterialization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("materialization-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("provider/large.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x41, count: 128 * 1024)
        try bytes.write(to: sourceURL)

        let ownerID = UUID()
        let generation: UInt64 = 17
        let book = Book(id: UUID(), userId: ownerID, title: "Large", formatType: .epub, fileURL: "Books/\(UUID())/large.epub")
        let revision = UUID()
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token,
            sourceKind: .securityScopedOriginal,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion,
            expectedSHA256: digest,
            expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
        let persistence = MaterializationPersistenceStub(job: job)
        let bookStore = InMemoryBookStore(initial: [book])
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(
            rootURL: root,
            lifecycle: lifecycle,
            sourceRegistry: registry,
            persistence: persistence,
            bookStore: bookStore,
            currentGeneration: { generation }
        )

        let fingerprint = try await coordinator.materialize(book: book, token: token, sourceURL: sourceURL)

        let destination = root.appendingPathComponent(book.fileURL)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(fingerprint.sha256 == digest)
        #expect(await persistence.currentJob.phase == .ready)
        #expect(await persistence.currentFingerprint == fingerprint)
    }

    @Test("source mutation after presenter installation is rejected before registration publication")
    func rejectsSourceMutationBeforePublishingReadableRegistration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readable-mutation-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("provider/book.pdf")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = Data("original selected source".utf8)
        let changedBytes = Data("replaced selected source".utf8)
        try originalBytes.write(to: sourceURL)

        let ownerID = UUID()
        let generation: UInt64 = 23
        let book = Book(id: UUID(), userId: ownerID, title: "Mutable", formatType: .pdf, fileURL: "Books/mutable.pdf")
        let revision = UUID()
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        let digest = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token,
            sourceKind: .securityScopedOriginal,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion,
            expectedSHA256: digest,
            expectedByteCount: Int64(originalBytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
        let persistence = MaterializationPersistenceStub(job: job)
        let bookStore = InMemoryBookStore(initial: [book])
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let events = BookImportEvents()
        let eventStream = await events.stream()
        let eventCounter = MaterializationEventCounter()
        let eventTask = Task {
            for await _ in eventStream { await eventCounter.increment() }
        }
        let sourceWasHiddenDuringProbe = SourceVisibilityObservation()
        let sourceMutationProbe = SourceMutationProbeObservation()
        let coordinator = BookMaterializationCoordinator(
            rootURL: root,
            lifecycle: lifecycle,
            sourceRegistry: registry,
            persistence: persistence,
            bookStore: bookStore,
            currentGeneration: { generation },
            events: events,
            reprobeSelectedSource: { url, materializationRevision in
                do {
                    _ = try await registry.acquireReadableSource(for: book)
                    await sourceWasHiddenDuringProbe.record(false)
                } catch {
                    await sourceWasHiddenDuringProbe.record(true)
                }
                let originalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let originalModificationDate = try #require(originalAttributes[.modificationDate] as? Date)
                let originalFileIdentifier = originalAttributes[.systemFileNumber] as? NSNumber
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: changedBytes)
                try handle.close()
                try FileManager.default.setAttributes([.modificationDate: originalModificationDate], ofItemAtPath: url.path)
                let result = try await CoordinatedSourceProbe().probe(
                    url,
                    materializationRevision: materializationRevision
                )
                let currentAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
                await sourceMutationProbe.record(
                    versionMatches: result.version == sourceVersion,
                    fileIdentifierMatches: currentAttributes[.systemFileNumber] as? NSNumber == originalFileIdentifier,
                    digestDiffers: result.sha256.caseInsensitiveCompare(digest) != .orderedSame
                )
                return (result.sha256, result.byteCount, result.version)
            }
        )

        await #expect(throws: BookMaterializationCoordinator.MaterializationError.sourceChanged) {
            try await coordinator.registerReadableSource(
                book: book,
                token: token,
                sourceURL: sourceURL,
                requiresSecurityScope: false
            )
        }

        #expect(await sourceWasHiddenDuringProbe.value)
        #expect(await sourceMutationProbe.versionMatches)
        #expect(await sourceMutationProbe.fileIdentifierMatches)
        #expect(await sourceMutationProbe.digestDiffers)
        #expect(await eventCounter.value == 0)
        #expect(await persistence.currentJob.phase == .paused)
        await #expect(throws: BookSourceRegistryError.unavailable) {
            try await registry.acquireReadableSource(for: book)
        }
        eventTask.cancel()
    }

    @Test("readers can acquire the source only after its verified registration is exposed")
    func exposesReadableSourceAfterVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readable-exposure-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("provider/book.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("verified original bytes".utf8)
        try bytes.write(to: sourceURL)

        let ownerID = UUID()
        let generation: UInt64 = 24
        let book = Book(id: UUID(), userId: ownerID, title: "Verified", formatType: .epub, fileURL: "Books/verified.epub")
        let revision = UUID()
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token,
            sourceKind: .securityScopedOriginal,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion,
            expectedSHA256: digest,
            expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
        let persistence = MaterializationPersistenceStub(job: job)
        let bookStore = InMemoryBookStore(initial: [book])
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let hiddenDuringProbe = SourceVisibilityObservation()
        let coordinator = BookMaterializationCoordinator(
            rootURL: root,
            lifecycle: lifecycle,
            sourceRegistry: registry,
            persistence: persistence,
            bookStore: bookStore,
            currentGeneration: { generation },
            reprobeSelectedSource: { url, materializationRevision in
                do {
                    _ = try await registry.acquireReadableSource(for: book)
                    await hiddenDuringProbe.record(false)
                } catch {
                    await hiddenDuringProbe.record(true)
                }
                let result = try await CoordinatedSourceProbe().probe(
                    url,
                    materializationRevision: materializationRevision
                )
                return (result.sha256, result.byteCount, result.version)
            }
        )

        try await coordinator.registerReadableSource(
            book: book,
            token: token,
            sourceURL: sourceURL,
            requiresSecurityScope: false
        )

        #expect(await hiddenDuringProbe.value)
        let source = try await registry.acquireReadableSource(for: book)
        #expect(source.url.standardizedFileURL == sourceURL.standardizedFileURL)
        #expect(source.cachePolicy == .transient)
        #expect(try Data(contentsOf: source.url) == bytes)
    }
}

private actor MaterializationEventCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor SourceMutationProbeObservation {
    private(set) var versionMatches = false
    private(set) var fileIdentifierMatches = false
    private(set) var digestDiffers = false

    func record(versionMatches: Bool, fileIdentifierMatches: Bool, digestDiffers: Bool) {
        self.versionMatches = versionMatches
        self.fileIdentifierMatches = fileIdentifierMatches
        self.digestDiffers = digestDiffers
    }
}

private actor SourceVisibilityObservation {
    private(set) var value = false
    func record(_ hidden: Bool) { value = hidden }
}

private actor MaterializationPersistenceStub: BookImportPersistence {
    private(set) var currentJob: PendingBookMaterialization
    private(set) var currentFingerprint: BookFileFingerprint?

    init(job: PendingBookMaterialization) { currentJob = job }

    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration {
        BookRegistration(book: book, token: job.token, disposition: .registered)
    }
    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? { nil }
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool {
        guard currentJob.token == token, currentJob.phase == from else { return false }
        currentJob = Self.copy(currentJob, phase: to)
        return true
    }
    func recordPrepared(token: BookMaterializationToken, artifacts: VerifiedBookArtifacts) async throws -> Bool {
        guard currentJob.token == token, currentJob.phase == .copying,
              artifacts.sha256 == currentJob.expectedSHA256,
              artifacts.byteCount == currentJob.expectedByteCount,
              let preparedFileIdentifier = artifacts.preparedFileIdentifier else { return false }
        currentJob = PendingBookMaterialization(
            token: token, sourceKind: currentJob.sourceKind, sourceBookmark: currentJob.sourceBookmark,
            ownedSourceRelativePath: currentJob.ownedSourceRelativePath, sourceVersion: currentJob.sourceVersion,
            expectedSHA256: currentJob.expectedSHA256, expectedByteCount: currentJob.expectedByteCount,
            stagingRelativePath: currentJob.stagingRelativePath, destinationRelativePath: currentJob.destinationRelativePath,
            phase: .prepared, preparedFileIdentifier: preparedFileIdentifier
        )
        return true
    }
    func claimPromotion(token: BookMaterializationToken, preparedFileIdentifier: String, promotionRevision: UUID) async throws -> Bool {
        guard currentJob.token == token, currentJob.phase == .prepared,
              currentJob.preparedFileIdentifier == preparedFileIdentifier else { return false }
        currentJob = PendingBookMaterialization(
            token: token, sourceKind: currentJob.sourceKind, sourceBookmark: currentJob.sourceBookmark,
            ownedSourceRelativePath: currentJob.ownedSourceRelativePath, sourceVersion: currentJob.sourceVersion,
            expectedSHA256: currentJob.expectedSHA256, expectedByteCount: currentJob.expectedByteCount,
            stagingRelativePath: currentJob.stagingRelativePath, destinationRelativePath: currentJob.destinationRelativePath,
            phase: .promoting, preparedFileIdentifier: preparedFileIdentifier, promotionRevision: promotionRevision
        )
        return true
    }
    func recordPromoted(token: BookMaterializationToken, preparedFileIdentifier: String, destinationFileIdentifier: String, promotionRevision: UUID) async throws -> Bool {
        guard currentJob.token == token, currentJob.phase == .promoting,
              currentJob.preparedFileIdentifier == preparedFileIdentifier,
              destinationFileIdentifier == preparedFileIdentifier,
              currentJob.promotionRevision == promotionRevision else { return false }
        currentJob = PendingBookMaterialization(
            token: token, sourceKind: currentJob.sourceKind, sourceBookmark: currentJob.sourceBookmark,
            ownedSourceRelativePath: currentJob.ownedSourceRelativePath, sourceVersion: currentJob.sourceVersion,
            expectedSHA256: currentJob.expectedSHA256, expectedByteCount: currentJob.expectedByteCount,
            stagingRelativePath: currentJob.stagingRelativePath, destinationRelativePath: currentJob.destinationRelativePath,
            phase: .promoted, preparedFileIdentifier: preparedFileIdentifier,
            destinationFileIdentifier: destinationFileIdentifier, promotionRevision: promotionRevision
        )
        return true
    }
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool {
        guard currentJob.token == token, currentJob.phase == .promoted else { return false }
        currentFingerprint = fingerprint
        currentJob = Self.copy(currentJob, phase: .ready)
        return true
    }
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool { false }
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? { nil }
    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        guard currentJob.token.bookID == bookID, currentJob.token.ownerID == ownerID else { return nil }
        return currentJob
    }
    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? {
        guard currentFingerprint?.bookID == bookID, currentFingerprint?.ownerID == ownerID else { return nil }
        return currentFingerprint
    }
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { false }
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws {}
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws {}

    private static func copy(_ job: PendingBookMaterialization, phase: BookMaterializationPhase) -> PendingBookMaterialization {
        PendingBookMaterialization(
            token: job.token, sourceKind: job.sourceKind, sourceBookmark: job.sourceBookmark,
            ownedSourceRelativePath: job.ownedSourceRelativePath, sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256, expectedByteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath, destinationRelativePath: job.destinationRelativePath,
            phase: phase, preparedFileIdentifier: job.preparedFileIdentifier,
            destinationFileIdentifier: job.destinationFileIdentifier, promotionRevision: job.promotionRevision
        )
    }
}

private actor MaterializationTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor MaterializationDrainProbe {
    private var complete = false
    func markComplete() { complete = true }
    func isComplete() -> Bool { complete }
}
