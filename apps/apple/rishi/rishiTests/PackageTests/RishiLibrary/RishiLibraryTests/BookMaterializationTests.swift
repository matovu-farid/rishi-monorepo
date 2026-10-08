import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import rishi

@Suite("Book materialization copy")
struct BookMaterializationTests {
    @Test("recovered sample repair never replaces a competing destination", arguments: [BookMaterializationPhase.prepared, .promoting])
    func recoveredSampleRepairKeepsCompetingBytes(phase: BookMaterializationPhase) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-recovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source/sample.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = Data("original sample bytes".utf8)
        try originalBytes.write(to: sourceURL)
        let ownerID = UUID()
        let generation: UInt64 = 7
        let book = Book(userId: ownerID, title: "Sample", formatType: .epub, fileURL: "Books/sample.epub")
        let destination = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalBytes.write(to: destination)
        let fingerprintRevision = UUID()
        let originalVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: destination, materializationRevision: fingerprintRevision))
        let digest = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: ownerID, sha256: digest, version: originalVersion)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: generation, contentRevision: fingerprintRevision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: originalVersion))
        try FileManager.default.removeItem(at: destination)

        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion, expectedSHA256: digest, expectedByteCount: Int64(originalBytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .registered
        )
        guard case .reserved = try await persistence.reserveSampleRepair(SampleRepairReservationRequest(
            expectedBook: book, expectedFingerprint: fingerprint, canonicalManagedURL: destination,
            expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
        )) else {
            Issue.record("missing sample did not reserve recovery attempt")
            return
        }
        #expect(try await persistence.transition(token: token, from: .registered, to: .copying))
        let stagingURL = root.appendingPathComponent(job.stagingRelativePath)
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalBytes.write(to: stagingURL)
        let stageVersion = try #require(try CoordinatedSourceProbe.version(at: stagingURL, revision: sourceVersion.materializationRevision))
        let preparedID = try #require(stageVersion.fileIdentifier)
        #expect(try await persistence.recordPrepared(token: token, artifacts: VerifiedBookArtifacts(
            sha256: digest, byteCount: Int64(originalBytes.count), stagingRelativePath: job.stagingRelativePath,
            destinationRelativePath: book.fileURL, preparedFileIdentifier: preparedID,
            destinationFileIdentifier: nil, promotionRevision: nil
        )))
        if phase == .promoting {
            #expect(try await persistence.claimPromotion(token: token, preparedFileIdentifier: preparedID, promotionRevision: UUID()))
        }

        let competingBytes = Data("independent writer's bytes".utf8)
        try competingBytes.write(to: destination)
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { generation }, currentOwnerID: { ownerID }, managedURL: { root.appendingPathComponent($0.fileURL) })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence, bookStore: books, currentGeneration: { generation })

        await #expect(throws: Error.self) { _ = try await coordinator.resumeRecovered(book: book, token: token) }
        #expect(try Data(contentsOf: destination) == competingBytes)
        #expect(try await books.book(book.id) == book)
        #expect(try await books.books(for: ownerID).count == 1)
        let storedFingerprint = try await db.read { context in
            try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).first?.value
        }
        #expect(try #require(storedFingerprint) == fingerprint)
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: ownerID) == nil)
    }

    @Test("sample repair activates when a legacy ready Book has no pending job")
    func legacySampleRepairActivatesWithoutPriorPendingJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-sample-repair-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source/alice.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FixtureBuilders.writeTinyEPUB(to: sourceURL, withCover: false)
        let bytes = try Data(contentsOf: sourceURL)
        let ownerID = UUID()
        let generation: UInt64 = 12
        let book = Book(userId: ownerID, title: "Legacy sample", formatType: .epub, fileURL: "Books/legacy.epub")
        let destination = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        let revision = UUID()
        let managedVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: destination, materializationRevision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: ownerID, sha256: digest, version: managedVersion)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: generation, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: managedVersion))
        try FileManager.default.removeItem(at: destination)

        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { generation }, currentOwnerID: { ownerID }, managedURL: { root.appendingPathComponent($0.fileURL) })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence, bookStore: books, currentGeneration: { generation })
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(token: token, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil, sourceVersion: sourceVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count), stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial", destinationRelativePath: book.fileURL, phase: .registered)
        let request = SampleRepairReservationRequest(expectedBook: book, expectedFingerprint: fingerprint, canonicalManagedURL: destination, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job)

        let result = try await coordinator.materializeReservedSampleRepair(request: request, sourceURL: sourceURL)
        guard case .repaired(let repairedFingerprint) = result else {
            Issue.record("legacy no-job sample repair did not materialize")
            return
        }
        #expect(repairedFingerprint.sha256 == digest)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try await books.books(for: ownerID).map(\.id) == [book.id])
        let pending = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID))
        #expect(pending.token == token)
        #expect(pending.phase == .ready)
    }

    @Test("guarded sample repair failure completes joined waiters and leaves an exact retry")
    func guardedRepairFailureCompletesWaitersAndAllowsRetry() async throws {
        let harness = try await makeBoundaryFixture()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let failureOnce = BoundaryCopyFailureOnce()
        let coordinator = harness.makeCoordinator(copySelectedSource: { token, source, stagingURL, sha, count, version in
            if await failureOnce.shouldFail() { throw BoundaryInjectedCopyFailure.failed }
            return try await CoordinatedBookCopier().copy(
                source: source, to: stagingURL, expectedSHA256: sha,
                expectedByteCount: count, sourceVersion: version
            )
        })
        let waiter = Task { try await harness.registry.awaitManagedSource(for: harness.book) }
        #expect(await waitForManagedWaiter(registry: harness.registry, book: harness.book, generation: harness.generation))

        await #expect(throws: Error.self) {
            _ = try await coordinator.materializeReservedSampleRepair(request: harness.request, sourceURL: harness.sourceURL)
        }
        #expect(await waiterFailsUnavailable(waiter), "the guarded failure permit must complete the joined waiter")
        let paused = try #require(await harness.persistence.pendingMaterialization(bookID: harness.book.id, ownerID: harness.ownerID))
        #expect(paused.token == harness.request.job.token)
        #expect(paused.phase == .paused)
        #expect(!FileManager.default.fileExists(atPath: harness.destination.path))

        let retryToken = BookMaterializationToken(ownerID: harness.ownerID, accountGeneration: harness.generation, bookID: harness.book.id, attemptID: UUID())
        let retrySourceVersion = try #require(try CoordinatedSourceProbe.version(at: harness.sourceURL, revision: UUID()))
        let retryJob = PendingBookMaterialization(
            token: retryToken, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: retrySourceVersion, expectedSHA256: harness.fingerprint.sha256,
            expectedByteCount: Int64(harness.bytes.count),
            stagingRelativePath: "Imports/\(retryToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: harness.book.fileURL, phase: .registered
        )
        let retryRequest = SampleRepairReservationRequest(
            expectedBook: harness.book, expectedFingerprint: harness.fingerprint,
            canonicalManagedURL: harness.destination, expectedManagedFileVersion: nil,
            expectedPriorPendingToken: paused.token, job: retryJob
        )
        guard case .repaired(let fingerprint) = try await harness.makeCoordinator().materializeReservedSampleRepair(
            request: retryRequest, sourceURL: harness.sourceURL
        ) else {
            Issue.record("exact retry did not repair the Book")
            return
        }
        #expect(fingerprint.sha256 == harness.fingerprint.sha256)
        #expect(try Data(contentsOf: harness.destination) == harness.bytes)
        #expect(try await harness.persistence.pendingMaterialization(bookID: harness.book.id, ownerID: harness.ownerID)?.phase == .ready)
    }

    @Test("account fence owns joined waiter revocation during a gated sample copy")
    func accountFenceWinsOverGuardedSampleFailure() async throws {
        let harness = try await makeBoundaryFixture()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let gate = MaterializationTestGate()
        let coordinator = harness.makeCoordinator(copySelectedSource: { _, source, stagingURL, sha, count, version in
            await gate.waitUntilReleased()
            return try await CoordinatedBookCopier().copy(
                source: source, to: stagingURL, expectedSHA256: sha,
                expectedByteCount: count, sourceVersion: version
            )
        })
        let waiter = Task { try await harness.registry.awaitManagedSource(for: harness.book) }
        #expect(await waitForManagedWaiter(registry: harness.registry, book: harness.book, generation: harness.generation))
        let repair = Task {
            try await coordinator.materializeReservedSampleRepair(request: harness.request, sourceURL: harness.sourceURL)
        }
        await gate.waitUntilEntered()
        _ = harness.lifecycle.fenceAccount(ownerID: harness.ownerID, generation: harness.generation)
        await #expect(throws: BookSourceRegistryError.accountRevoked) { _ = try await waiter.value }
        await gate.release()
        await #expect(throws: Error.self) { _ = try await repair.value }
        let pending = try #require(await harness.persistence.pendingMaterialization(bookID: harness.book.id, ownerID: harness.ownerID))
        #expect(pending.token == harness.request.job.token)
        #expect(pending.phase != .ready)
        #expect(!FileManager.default.fileExists(atPath: harness.destination.path))
    }

    @Test("stale sample failure permit cannot fail a waiter admitted in a newer registry epoch")
    func staleSampleFailurePermitDoesNotCompleteNewerWaiter() async throws {
        let harness = try await makeBoundaryFixture()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let reachedPromotion = DispatchSemaphore(value: 0)
        let resumePromotion = DispatchSemaphore(value: 0)
        let competingBytes = Data("newer managed writer".utf8)
        let coordinator = harness.makeCoordinator(beforeRepairPromotion: { url in
            _ = harness.registry.advanceBookAttemptSynchronously(
                ownerID: harness.ownerID, generation: harness.generation, bookID: harness.book.id
            )
            reachedPromotion.signal()
            resumePromotion.wait()
            try competingBytes.write(to: url)
        })
        let repair = Task {
            try await coordinator.materializeReservedSampleRepair(request: harness.request, sourceURL: harness.sourceURL)
        }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: reachedPromotion.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(reached)
        let newerWaiter = Task { try await harness.registry.awaitManagedSource(for: harness.book) }
        #expect(await waitForManagedWaiter(registry: harness.registry, book: harness.book, generation: harness.generation))
        resumePromotion.signal()
        await #expect(throws: Error.self) { _ = try await repair.value }
        #expect(await harness.registry.hasManagedWaiterForTesting(ownerID: harness.ownerID, generation: harness.generation, bookID: harness.book.id))
        #expect(try Data(contentsOf: harness.destination) == competingBytes)
        newerWaiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await newerWaiter.value }
    }

    @Test("sample repair cannot replace bytes that arrive after reservation")
    func sampleRepairPromotionLeavesCompetingDestinationUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-race-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source/sample.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FixtureBuilders.writeTinyEPUB(to: sourceURL, withCover: false)
        let sampleBytes = try Data(contentsOf: sourceURL)
        let ownerID = UUID()
        let generation: UInt64 = 7
        let book = Book(userId: ownerID, title: "Sample", formatType: .epub, fileURL: "Books/sample.epub")
        let destination = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sampleBytes.write(to: destination)
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: destination, materializationRevision: revision))
        let digest = SHA256.hash(data: sampleBytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: ownerID, sha256: digest, version: version)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: generation, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: version))
        try FileManager.default.removeItem(at: destination)

        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { generation }, currentOwnerID: { ownerID }, managedURL: { root.appendingPathComponent($0.fileURL) })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let competingBytes = Data("independent writer's content".utf8)
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence,
            bookStore: books, currentGeneration: { generation },
            beforeRepairPromotion: { destinationURL in
                try competingBytes.write(to: destinationURL)
            }
        )
        let storage = BookFileStorage(
            rootURL: root, bookStore: books, coverExtractors: [:], metadataExtractors: [:],
            fingerprintPersistence: persistence, fingerprintAccountGeneration: { generation },
            materializationCoordinator: coordinator
        )

        await #expect(throws: Error.self) {
            _ = try await storage.repairMissingSample(for: book, from: sourceURL, ownerID: ownerID, accountGeneration: generation)
        }
        #expect(try Data(contentsOf: destination) == competingBytes)
        #expect(try await books.book(book.id) == book)
        #expect(try await books.books(for: ownerID).count == 1)
    }

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

    @Test("same-owner retries adopt two newer generations from the exact paused source after old bytes disappear")
    func retriesAcrossTwoReloginsKeepCanonicalAuthorityAndIgnoreDrainedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-relogin-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("provider/selected.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("selected source survives relogin retry".utf8)
        try bytes.write(to: sourceURL)
        let ownerID = UUID()
        let generationState = MaterializationGenerationState(0)
        let book = Book(id: UUID(), userId: ownerID, title: "Retry across relogin", formatType: .epub, fileURL: "Books/\(UUID())/selected.epub")
        let revision = UUID()
        let sourceVersion0 = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let token0 = BookMaterializationToken(ownerID: ownerID, accountGeneration: 0, bookID: book.id, attemptID: UUID())
        let failed = PendingBookMaterialization(
            token: token0, sourceKind: .securityScopedOriginal, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion0, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/\(token0.attemptID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL, phase: .registered
        )
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let books = SwiftDataBookStore(dbStore: db)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: 0)
        #expect(try await persistence.reserveRegistration(book: book, job: failed).disposition == .registered)
        #expect(try await persistence.transition(token: token0, from: .registered, to: .copying))
        #expect(try await persistence.transition(token: token0, from: .copying, to: .failed))

        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { await generationState.get() },
            currentOwnerID: { ownerID },
            startSecurityScope: { _ in true },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { await generationState.get() })
        let oldAttempt = try #require(lifecycle.admitBookMaterialization(token0))
        oldAttempt.release()
        let scopeProbe = RetrySourceScopeProbe()
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence,
            bookStore: books, currentGeneration: { await generationState.get() },
            reprobeSelectedSource: { url, revision in
                #expect(scopeProbe.selectedScopeIsActive)
                let result = try await CoordinatedSourceProbe().probe(url, materializationRevision: revision)
                return (result.sha256, result.byteCount, result.version)
            },
            startSelectedSourceScope: { _ in scopeProbe.startSelectedScope() },
            stopSelectedSourceScope: { _ in scopeProbe.stopSelectedScope() }
        )
        let originalRevision = try #require(await persistence.retryExpectation(
            bookID: book.id, ownerID: ownerID, accountPermit: AccountMutationPermit(ownerID: ownerID, accountGeneration: 0)
        )).readingPermit.contentRevision

        func enterGeneration(_ generation: UInt64, leaving oldGeneration: UInt64) async throws {
            lifecycle.fenceAccount(ownerID: ownerID, generation: oldGeneration)
            await lifecycle.drainAccount(ownerID, generation: oldGeneration)
            try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
            await generationState.set(generation)
            #expect(lifecycle.activateAccount(ownerID: ownerID, generation: generation))
        }

        func selectedSource(_ generation: UInt64) throws -> PendingBookMaterialization {
            let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
            let selectedVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
            return PendingBookMaterialization(
                token: token, sourceKind: .securityScopedOriginal, sourceBookmark: nil, ownedSourceRelativePath: nil,
                sourceVersion: selectedVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
                stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
                destinationRelativePath: book.fileURL, phase: .registered
            )
        }

        try await enterGeneration(1, leaving: 0)
        let permit1 = AccountMutationPermit(ownerID: ownerID, accountGeneration: 1)
        let expected0 = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: ownerID, accountPermit: permit1))
        let source1 = try selectedSource(1)
        let postCASCancellation = RetryTaskCancellation()
        let firstRetry = Task {
            try await coordinator.retryAndRegisterReadableSource(
                book: book, accountPermit: permit1, retryExpectation: expected0, newSource: source1,
                retiredAttempt: RetiredBookMaterializationAttempt(token: token0), sourceURL: sourceURL,
                requiresSecurityScope: true,
                onRegistrationAccepted: { postCASCancellation.cancel() }
            )
        }
        postCASCancellation.install { firstRetry.cancel() }
        await #expect(throws: CancellationError.self) { try await firstRetry.value }
        #expect(scopeProbe.selectedScopeCounts == (starts: 1, stops: 1, active: 0))
        try FileManager.default.removeItem(at: sourceURL)
        try bytes.write(to: sourceURL)
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID)?.phase == .paused)
        #expect(try await books.book(book.id) == book)
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: 0) == nil)
        #expect(try #require(await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: 1)).contentRevision == originalRevision)

        try await enterGeneration(2, leaving: 1)
        let permit2 = AccountMutationPermit(ownerID: ownerID, accountGeneration: 2)
        let expected1 = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: ownerID, accountPermit: permit2))
        #expect(expected1.pending.token == source1.token)
        #expect(expected1.readingPermit.contentRevision == originalRevision)
        let source2 = try selectedSource(2)
        let secondRetry = try await coordinator.retryAndRegisterReadableSource(
            book: book, accountPermit: permit2, retryExpectation: expected1, newSource: source2,
            retiredAttempt: RetiredBookMaterializationAttempt(token: source1.token), sourceURL: sourceURL,
            requiresSecurityScope: true
        )
        #expect(scopeProbe.selectedScopeCounts == (starts: 2, stops: 2, active: 0))
        #expect(secondRetry.registration.token == source2.token)
        #expect(try #require(await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: 2)).contentRevision == originalRevision)
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: 1) == nil)
        let ready = try await coordinator.materialize(book: book, token: source2.token, sourceURL: sourceURL,
                                                       reuseRegisteredSource: true, admission: secondRetry.admission)
        #expect(ready.sha256 == digest)
        #expect(try Data(contentsOf: root.appendingPathComponent(book.fileURL)) == bytes)
    }

    @Test("cancellation at retry publication removes the transient source and emits no registration")
    func cancelledRetryPublicationLeavesOnlyPausedAdoptedAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-publication-cancel-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("provider/selected.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("publication cancellation keeps adopted bytes".utf8)
        try bytes.write(to: sourceURL)
        let ownerID = UUID()
        let generationState = MaterializationGenerationState(0)
        let book = Book(userId: ownerID, title: "Publication cancel", formatType: .epub, fileURL: "Books/publication-cancel.epub")
        let revision = UUID()
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let retiredToken = BookMaterializationToken(ownerID: ownerID, accountGeneration: 0, bookID: book.id, attemptID: UUID())
        let retiredJob = PendingBookMaterialization(
            token: retiredToken, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/retired/content.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let books = SwiftDataBookStore(dbStore: db)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: 0)
        #expect(try await persistence.reserveRegistration(book: book, job: retiredJob).disposition == .registered)
        #expect(try await persistence.transition(token: retiredToken, from: .registered, to: .copying))
        #expect(try await persistence.transition(token: retiredToken, from: .copying, to: .failed))
        let events = BookImportEvents()
        let eventStream = await events.stream()
        let receivedEvents = RetryPublicationEventRecorder()
        let eventReader = Task {
            for await event in eventStream { await receivedEvents.record(event) }
        }
        let registry = BookSourceRegistry(
            persistence: persistence, currentGeneration: { await generationState.get() }, currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { await generationState.get() })
        lifecycle.fenceAccount(ownerID: ownerID, generation: 0)
        await lifecycle.drainAccount(ownerID, generation: 0)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: 1)
        await generationState.set(1)
        #expect(lifecycle.activateAccount(ownerID: ownerID, generation: 1))

        let publicationGate = RetryPublicationTestGate()
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence, bookStore: books,
            currentGeneration: { await generationState.get() }, events: events,
            beforeRetryRegisteredPublication: { await publicationGate.wait() }
        )
        let newSource = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: ownerID, accountGeneration: 1, bookID: book.id, attemptID: UUID()),
            sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/adopted/content.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
        let permit = AccountMutationPermit(ownerID: ownerID, accountGeneration: 1)
        let expectation = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: ownerID, accountPermit: permit))
        let retry = Task {
            try await coordinator.retryAndRegisterReadableSource(
                book: book, accountPermit: permit, retryExpectation: expectation, newSource: newSource,
                retiredAttempt: RetiredBookMaterializationAttempt(token: retiredToken), sourceURL: sourceURL,
                requiresSecurityScope: false
            )
        }
        #expect(await publicationGate.waitUntilEntered())
        retry.cancel()
        await publicationGate.release()
        await #expect(throws: CancellationError.self) { try await retry.value }
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID)?.token == newSource.token)
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID)?.phase == .paused)
        #expect(try await books.book(book.id) == book)
        await #expect(throws: BookSourceRegistryError.unavailable) { try await registry.acquireReadableSource(for: book) }
        await registry.drainBook(ownerID: ownerID, generation: 1, bookID: book.id)
        await lifecycle.drainAccount(ownerID, generation: 1)
        try await Task.sleep(for: .milliseconds(30))
        eventReader.cancel()
        await eventReader.value
        #expect(await receivedEvents.registeredTokens.isEmpty)
    }

    @Test("second retry probe failure preserves canonical children, adopted staging, and retained original source writes")
    func retrySecondProbeFailurePreservesCanonicalAndRetainedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-second-probe-failure-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("provider/original.epub")
        let retryURL = root.appendingPathComponent("Imports/retry/source.epub")
        let canonicalURL = root.appendingPathComponent("Books/retained-source.epub")
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canonicalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("same-owner retry source bytes".utf8)
        let canonicalBytes = Data("canonical managed bytes remain intact".utf8)
        try bytes.write(to: originalURL)
        try bytes.write(to: retryURL)
        try canonicalBytes.write(to: canonicalURL)
        let ownerID = UUID()
        let generation: UInt64 = 0
        let book = Book(userId: ownerID, title: "Retained source", formatType: .epub, fileURL: "Books/retained-source.epub")
        let revision = UUID()
        let originalVersion = try #require(try CoordinatedSourceProbe.version(at: originalURL, revision: revision))
        let retryVersion = try #require(try CoordinatedSourceProbe.version(at: retryURL, revision: UUID()))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let oldToken = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let oldJob = PendingBookMaterialization(
            token: oldToken, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: originalVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/old/content.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let books = SwiftDataBookStore(dbStore: db)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        #expect(try await persistence.reserveRegistration(book: book, job: oldJob).disposition == .registered)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: generation, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.transition(token: oldToken, from: .registered, to: .copying))
        #expect(try await persistence.transition(token: oldToken, from: .copying, to: .failed))
        let permit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: generation))
        let registry = BookSourceRegistry(
            persistence: persistence, currentGeneration: { generation }, currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        try await registry.registerSource(
            for: book, url: originalURL, accountGeneration: generation, readingPermit: permit,
            requiresSecurityScope: false, observeChanges: false
        )
        let originalLease = try await registry.acquireReadableSource(for: book)
        let mutations = BookScopedMutationStore(dbStore: db)
        let originalBookmark = Bookmark(bookId: book.id, locator: "original-reader")
        let originalPosition = Position(bookId: book.id, locator: "epubcfi(/6/2)")
        let originalHighlight = Highlight(bookId: book.id, locatorStart: "start", locatorEnd: "end", color: .yellow, text: "Retained")
        try await mutations.upsert(originalBookmark, permit: permit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority)
        try await mutations.upsert(originalPosition, permit: permit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority)
        try await mutations.upsert(originalHighlight, permit: permit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority)
        try await mutations.withSettingsWrite(permit: permit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority) { _ in "dark" }

        let newToken = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let newSource = PendingBookMaterialization(
            token: newToken, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: "Imports/retry/source.epub",
            sourceVersion: retryVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/retry/content.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
        let probeCount = RetryProbeCounter()
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence,
            bookStore: books, currentGeneration: { generation },
            reprobeSelectedSource: { url, sourceRevision in
                let probe = await probeCount.next()
                if probe == 2 { throw RetrySourceProbeFailure.secondProbe }
                if probe == 4 { throw CancellationError() }
                let result = try await CoordinatedSourceProbe().probe(url, materializationRevision: sourceRevision)
                return (result.sha256, result.byteCount, result.version)
            }
        )
        let accountPermit = AccountMutationPermit(ownerID: ownerID, accountGeneration: generation)
        let expectation = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: ownerID, accountPermit: accountPermit))
        await #expect(throws: BookMaterializationCoordinator.MaterializationError.sourceChanged) {
            _ = try await coordinator.retryAndRegisterReadableSource(
                book: book, accountPermit: accountPermit, retryExpectation: expectation, newSource: newSource,
                retiredAttempt: RetiredBookMaterializationAttempt(token: oldToken), sourceURL: retryURL,
                requiresSecurityScope: false
            )
        }

        #expect(try await books.book(book.id) == book)
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: generation) == permit)
        let paused = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID))
        #expect(paused.token == newToken)
        #expect(paused.phase == .paused)
        #expect(try Data(contentsOf: retryURL) == bytes)
        #expect(try Data(contentsOf: canonicalURL) == canonicalBytes)
        #expect(try await SwiftDataBookmarkStore(dbStore: db).bookmarks(for: book.id) == [originalBookmark])
        #expect(try await SwiftDataPositionStore(dbStore: db).position(for: book.id) == originalPosition)
        #expect(try await SwiftDataHighlightStore(dbStore: db).highlights(for: book.id) == [originalHighlight])

        let cancelledToken = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let cancelledSource = PendingBookMaterialization(
            token: cancelledToken, sourceKind: .ownedStaging, sourceBookmark: nil, ownedSourceRelativePath: "Imports/retry/source.epub",
            sourceVersion: retryVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count),
            stagingRelativePath: "Imports/retry-cancelled/content.partial", destinationRelativePath: book.fileURL, phase: .registered
        )
        let retryExpectation = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: ownerID, accountPermit: accountPermit))
        await #expect(throws: CancellationError.self) {
            _ = try await coordinator.retryAndRegisterReadableSource(
                book: book, accountPermit: accountPermit, retryExpectation: retryExpectation, newSource: cancelledSource,
                retiredAttempt: RetiredBookMaterializationAttempt(token: newToken), sourceURL: retryURL,
                requiresSecurityScope: false
            )
        }
        let cancelled = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: ownerID))
        #expect(cancelled.token == cancelledToken)
        #expect(cancelled.phase == .paused)
        #expect(try Data(contentsOf: canonicalURL) == canonicalBytes)
        #expect(try Data(contentsOf: retryURL) == bytes)
        try await mutations.upsert(Bookmark(bookId: book.id, locator: "after-failed-retry"), permit: permit,
                                   originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority)
        try await mutations.withSettingsWrite(permit: permit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority) { _ in "light" }
        #expect(try await SwiftDataBookmarkStore(dbStore: db).bookmarks(for: book.id).count == 2)
    }

    @Test("original and managed leases keep one canonical permit across identical promotion")
    func originalAndManagedLeasesShareCanonicalPermitAcrossPromotion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-promotion-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("provider/book.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("same verified bytes through promotion".utf8)
        try bytes.write(to: sourceURL)

        let ownerID = UUID()
        let generation: UInt64 = 37
        let book = Book(id: UUID(), userId: ownerID, title: "Canonical", formatType: .epub, fileURL: "Books/\(UUID().uuidString)/book.epub")
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let sourceRevision = UUID()
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: sourceRevision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
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
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        #expect(try await persistence.reserveRegistration(book: book, job: job).disposition == .registered)
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
            bookStore: books,
            currentGeneration: { generation }
        )

        try await coordinator.registerReadableSource(book: book, token: token, sourceURL: sourceURL, requiresSecurityScope: false)
        let originalLease = try await registry.acquireReadableSource(for: book)
        guard case let .account(originalPermit) = originalLease.access else {
            Issue.record("the selected source lease did not carry the canonical Book permit")
            return
        }
        let fingerprint = try await coordinator.materialize(
            book: book,
            token: token,
            sourceURL: sourceURL,
            publishRegistration: true,
            reuseRegisteredSource: true
        )
        let managed = try #require(try await registry.managedSource(for: book))
        let managedLease = try await registry.acquireReadableSource(for: book)
        guard case let .account(managedPermit) = managedLease.access else {
            Issue.record("the managed source lease did not carry the canonical Book permit")
            return
        }
        #expect(fingerprint.sha256 == digest)
        #expect(originalPermit == managedPermit)
        #expect(managed.readingPermit == originalPermit)
        #expect(managed.fingerprint == fingerprint)

        let mutations = BookScopedMutationStore(dbStore: db)
        try await mutations.upsert(
            Position(bookId: book.id, locator: "original-position"), permit: originalPermit,
            originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority
        )
        try await mutations.upsert(
            Position(bookId: book.id, locator: "managed-position"), permit: managedPermit,
            originatingSource: managedLease.sourceAccessPermit, sourceEffects: managedLease.effectAuthority
        )
        try await mutations.upsert(
            Bookmark(bookId: book.id, locator: "original-bookmark"), permit: originalPermit,
            originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority
        )
        try await mutations.upsert(
            Bookmark(bookId: book.id, locator: "managed-bookmark"), permit: managedPermit,
            originatingSource: managedLease.sourceAccessPermit, sourceEffects: managedLease.effectAuthority
        )
        try await mutations.upsert(
            Highlight(bookId: book.id, locatorStart: "original-start", locatorEnd: "original-end", color: .yellow, text: "Original"),
            permit: originalPermit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority
        )
        try await mutations.upsert(
            Highlight(bookId: book.id, locatorStart: "managed-start", locatorEnd: "managed-end", color: .blue, text: "Managed"),
            permit: managedPermit, originatingSource: managedLease.sourceAccessPermit, sourceEffects: managedLease.effectAuthority
        )
        try await mutations.withSettingsWrite(
            permit: originalPermit, originatingSource: originalLease.sourceAccessPermit, sourceEffects: originalLease.effectAuthority
        ) { _ in "original" }
        try await mutations.withSettingsWrite(
            permit: managedPermit, originatingSource: managedLease.sourceAccessPermit, sourceEffects: managedLease.effectAuthority
        ) { _ in "managed" }
        #expect(try await db.read { context in
            try context.fetch(FetchDescriptor<PositionEntity>()).filter { $0.bookId == book.id }.count
        } == 2)
        #expect(try await SwiftDataBookmarkStore(dbStore: db).bookmarks(for: book.id).count == 2)
        #expect(try await SwiftDataHighlightStore(dbStore: db).highlights(for: book.id).count == 2)

        originalLease.owner.invalidation.invalidate()
        originalLease.effectAuthority.closeAdmission(originalLease.sourceAccessPermit)
        #expect(throws: BookSourceAccessError.revoked) {
            try originalLease.effectAuthority.admit(originalLease.sourceAccessPermit)
        }
        await originalLease.effectAuthority.drain(originalLease.sourceAccessPermit)
        #expect(throws: BookSourceAccessError.unknownSource) {
            try originalLease.effectAuthority.admit(originalLease.sourceAccessPermit)
        }
        let managedAdmission = try managedLease.effectAuthority.admit(managedLease.sourceAccessPermit)
        managedAdmission.release()
        try await mutations.upsert(
            Position(bookId: book.id, locator: "managed-still-live"), permit: managedPermit,
            originatingSource: managedLease.sourceAccessPermit, sourceEffects: managedLease.effectAuthority
        )
        #expect(try await SwiftDataPositionStore(dbStore: db).position(for: book.id)?.locator == "managed-still-live")
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
        let collisionModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: collisionModificationDate], ofItemAtPath: sourceURL.path)

        let ownerID = UUID()
        let generation: UInt64 = 23
        let book = Book(id: UUID(), userId: ownerID, title: "Mutable", formatType: .pdf, fileURL: "Books/mutable.pdf")
        let revision = UUID()
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: revision))
        #expect(sourceVersion.modificationDate == collisionModificationDate)
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
        #expect(await sourceMutationProbe.versionMatches, "changed bytes retained the complete original file version")
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

private extension BookMaterializationTests {
    func waitForManagedWaiter(registry: BookSourceRegistry, book: Book, generation: UInt64) async -> Bool {
        for _ in 0..<500 {
            if await registry.hasManagedWaiterForTesting(ownerID: book.userId, generation: generation, bookID: book.id) { return true }
            await Task.yield()
        }
        return false
    }

    func waiterFailsUnavailable(
        _ waiter: Task<ManagedBookSource, any Error>,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let result = WaiterOutcomeGate()
        Task {
            do {
                _ = try await waiter.value
                await result.resolve(false)
            } catch let error as BookSourceRegistryError {
                await result.resolve(error == .unavailable)
            } catch {
                await result.resolve(false)
            }
        }
        let timeoutTask = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            waiter.cancel()
            await result.resolve(false)
        }
        let didFailUnavailable = await result.wait()
        timeoutTask.cancel()
        return didFailUnavailable
    }

    func makeBoundaryFixture() async throws -> SampleRepairBoundaryFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sample-repair-boundary-\(UUID())", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source/sample.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FixtureBuilders.writeTinyEPUB(to: sourceURL, withCover: false)
        let bytes = try Data(contentsOf: sourceURL)
        let ownerID = UUID()
        let generation: UInt64 = 19
        let book = Book(userId: ownerID, title: "Sample", formatType: .epub, fileURL: "Books/sample.epub")
        let destination = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination)
        let revision = UUID()
        let managedVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: destination, materializationRevision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: ownerID, sha256: digest, version: managedVersion)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: generation, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: managedVersion))
        try FileManager.default.removeItem(at: destination)
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { generation }, currentOwnerID: { ownerID }, managedURL: { root.appendingPathComponent($0.fileURL) })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: sourceURL, revision: UUID()))
        let token = BookMaterializationToken(ownerID: ownerID, accountGeneration: generation, bookID: book.id, attemptID: UUID())
        let job = PendingBookMaterialization(token: token, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil, sourceVersion: sourceVersion, expectedSHA256: digest, expectedByteCount: Int64(bytes.count), stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial", destinationRelativePath: book.fileURL, phase: .registered)
        let request = SampleRepairReservationRequest(expectedBook: book, expectedFingerprint: fingerprint, canonicalManagedURL: destination, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job)
        return SampleRepairBoundaryFixture(root: root, sourceURL: sourceURL, bytes: bytes, ownerID: ownerID, generation: generation, book: book, destination: destination, fingerprint: fingerprint, persistence: persistence, books: books, registry: registry, lifecycle: lifecycle, request: request)
    }
}

private actor WaiterOutcomeGate {
    private var outcome: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome { continuation.resume(returning: outcome) }
            else { self.continuation = continuation }
        }
    }

    func resolve(_ value: Bool) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
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
    func readingPermit(bookID: BookID, ownerID: UserID, generation: UInt64) async throws -> BookReadingPermit? {
        guard currentJob.token.bookID == bookID, currentJob.token.ownerID == ownerID,
              currentJob.token.accountGeneration == generation else { return nil }
        return BookReadingPermit(ownerID: ownerID, accountGeneration: generation, bookID: bookID, contentRevision: currentJob.sourceVersion.materializationRevision)
    }
    func readingPermit(forManagedFingerprint expected: BookFileFingerprint, expectedRelativePath: String, generation: UInt64) async throws -> BookReadingPermit? {
        guard let currentFingerprint,
              currentJob.token.bookID == expected.bookID, currentJob.token.ownerID == expected.ownerID,
              currentJob.token.accountGeneration == generation, currentJob.phase == .ready,
              currentJob.destinationRelativePath == expectedRelativePath,
              currentFingerprint.sha256.caseInsensitiveCompare(expected.sha256) == .orderedSame,
              currentFingerprint.version == expected.version else { return nil }
        return BookReadingPermit(ownerID: expected.ownerID, accountGeneration: generation, bookID: expected.bookID, contentRevision: currentJob.sourceVersion.materializationRevision)
    }
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


    // Explicit negative results for operations outside this fixture's controlled scenario.
    func cacheManagedFingerprint(_ fingerprint: BookFileFingerprint, expectedGeneration: UInt64, expectedRelativePath: String, expectedVersion: ManagedFileVersion) async throws -> Bool { false }
    func reauthorizeReadyManagedSource(bookID: BookID, ownerID: UserID, generation: UInt64, fingerprint: BookFileFingerprint) async throws -> Bool { false }
    func parkSampleRepair(book: Book, token: BookMaterializationToken) async -> SampleRepairParkingOutcome { .writeFailed }
    func discardUnpublishedRegistration(token: BookMaterializationToken) async throws -> Bool { false }
    func retryExpectation(bookID: BookID, ownerID: UserID, accountPermit: AccountMutationPermit) async throws -> BookImportRetryExpectation? { nil }
    func retryPendingMaterialization(expected: BookImportRetryExpectation, accountPermit: AccountMutationPermit, newSource: PendingBookMaterialization, verifiedSourceSHA256: String, verifiedSourceByteCount: Int64, verifiedSourceVersion: ManagedFileVersion, retiredAttempt: RetiredBookMaterializationAttempt) async throws -> BookRegistration? { nil }
    func quarantineRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID) async throws -> BookMaterializationToken? { nil }
    func reauthorizeWaitingRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64) async throws -> BookMaterializationToken? { nil }
    func refreshSourceBookmark(token: BookMaterializationToken, refreshedData: Data) async throws -> Bool { false }
    func pendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? { try await pendingMaterialization(bookID: bookID, ownerID: ownerID) }
    func pendingMaterializationsForDeletionCleanup(ownerID: UserID) async throws -> [PendingBookMaterialization] { [] }
    func isBookPermanentlyDeleted(bookID: BookID, ownerID: UserID) async throws -> Bool { false }
    func deletePendingMaterializationForDeletionCleanup(bookID: BookID, ownerID: UserID, expectedToken: BookMaterializationToken) async throws -> Bool { false }
    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? { try await pendingMaterialization(bookID: bookID, ownerID: ownerID) }
    func sampleRepairFingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? { try await fingerprint(bookID: bookID, ownerID: ownerID) }
    func recordServerAcceptance(permit: BookReadingPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool { false }
    func recordServerAcceptance(accountPermit: AccountMutationPermit, expectedFingerprint: BookFileFingerprint, acceptance: BookServerAcceptance) async throws -> Bool { false }
}

private enum BoundaryInjectedCopyFailure: Error { case failed }

private actor BoundaryCopyFailureOnce {
    private var failed = false
    func shouldFail() -> Bool {
        guard !failed else { return false }
        failed = true
        return true
    }
}

private struct SampleRepairBoundaryFixture {
    let root: URL
    let sourceURL: URL
    let bytes: Data
    let ownerID: UserID
    let generation: UInt64
    let book: Book
    let destination: URL
    let fingerprint: BookFileFingerprint
    let persistence: SwiftDataBookImportPersistence
    let books: SwiftDataBookStore
    let registry: BookSourceRegistry
    let lifecycle: BookImportLifecycle
    let request: SampleRepairReservationRequest

    func makeCoordinator(
        copySelectedSource: (@Sendable (BookMaterializationToken, BookSourceLease, URL, String, Int64, ManagedFileVersion) async throws -> StagedBookArtifact)? = nil,
        beforeRepairPromotion: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> BookMaterializationCoordinator {
        BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry,
            persistence: persistence, bookStore: books, currentGeneration: { generation },
            copySelectedSource: copySelectedSource, beforeRepairPromotion: beforeRepairPromotion
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

private actor MaterializationGenerationState {
    private var generation: UInt64
    init(_ generation: UInt64) { self.generation = generation }
    func get() -> UInt64 { generation }
    func set(_ generation: UInt64) { self.generation = generation }
}

private final class RetrySourceScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = 0

    var selectedScopeIsActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active > 0
    }

    var selectedScopeCounts: (starts: Int, stops: Int, active: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, stops, active)
    }

    func startSelectedScope() -> Bool {
        lock.lock(); defer { lock.unlock() }
        starts += 1
        active += 1
        return true
    }

    func stopSelectedScope() {
        lock.lock(); defer { lock.unlock() }
        stops += 1
        active -= 1
    }
}

private final class RetryTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var requested = false

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let shouldCancel = requested
        lock.unlock()
        if shouldCancel { action() }
    }

    func cancel() {
        lock.lock()
        requested = true
        let action = self.action
        lock.unlock()
        action?()
    }
}

private actor RetryPublicationEventRecorder {
    private(set) var registeredTokens: [BookMaterializationToken] = []
    func record(_ event: BookImportEvent) {
        if case .registered = event.kind { registeredTokens.append(event.token) }
    }
}

private actor RetryPublicationTestGate {
    private var entered = false
    private var released = false
    private var continuation: AsyncStream<Void>.Continuation?

    func wait() async {
        entered = true
        guard !released else { return }
        let stream = AsyncStream<Void> { continuation in self.continuation = continuation }
        await withTaskCancellationHandler {
            for await _ in stream { break }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }

    func waitUntilEntered() async -> Bool {
        for _ in 0..<200 {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.yield(())
        continuation?.finish()
        continuation = nil
    }

    private func cancelWait() {
        continuation?.finish()
        continuation = nil
    }
}

private actor RetryProbeCounter {
    private var calls = 0
    func next() -> Int { calls += 1; return calls }
}

private enum RetrySourceProbeFailure: Error {
    case secondProbe
}
