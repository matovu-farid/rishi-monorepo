@testable import rishi
import Foundation
import SwiftData
import Testing

@Suite("Book import persistence", .serialized)
struct BookImportPersistenceTests {
    @Test("materialization values preserve bookmark, dates, and prepared provenance in JSON")
    func materializationJSONRoundTrip() throws {
        let token = BookMaterializationToken(ownerID: UUID(), accountGeneration: .max, bookID: UUID(), attemptID: UUID())
        let version = ManagedFileVersion(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 123.5), fileIdentifier: "source-1", materializationRevision: UUID())
        let job = PendingBookMaterialization(token: token, sourceKind: .securityScopedOriginal, sourceBookmark: Data([0, 1, 2, 255]), ownedSourceRelativePath: nil, sourceVersion: version, expectedSHA256: "aabb", expectedByteCount: 42, stagingRelativePath: "staging/book.part", destinationRelativePath: "books/book.epub", phase: .prepared, preparedFileIdentifier: "prepared-1", destinationFileIdentifier: "destination-1", promotionRevision: UUID())

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(PendingBookMaterialization.self, from: data)

        #expect(decoded == job)
        #expect(decoded.token.accountGeneration == .max)
        #expect(decoded.sourceBookmark == Data([0, 1, 2, 255]))
        #expect(decoded.preparedFileIdentifier == "prepared-1")
        #expect(decoded.destinationFileIdentifier == "destination-1")
        #expect(decoded.promotionRevision == job.promotionRevision)
    }

    @Test("RishiDBStore rolls back writes that throw")
    func writeRollback() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let book = makeBook()
        do {
            try await db.write { context in
                context.insert(BookEntity(id: book.id, userId: book.userId, title: book.title, author: book.author, formatTypeRawValue: book.formatType.rawValue, addedAt: book.addedAt, openedAt: book.openedAt, fileURL: book.fileURL, coverPath: book.coverPath, positionId: book.positionId, conversationId: book.conversationId))
                throw TestFailure.expected
            }
            Issue.record("write unexpectedly succeeded")
        } catch TestFailure.expected {
        }

        #expect(try await SwiftDataBookStore(dbStore: db).book(book.id) == nil)
    }

    @Test("reservation and phase changes reject stale attempts and isolate owners")
    func reservationCASAndOwnerIsolation() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        let registration = try await persistence.reserveRegistration(book: book, job: job)
        #expect(registration.disposition == .registered)
        #expect(registration.token == job.token)

        let duplicateBook = Book(id: UUID(), userId: book.userId, title: "Duplicate selection", formatType: .pdf, fileURL: "books/duplicate.pdf")
        let duplicateJob = makeJob(book: duplicateBook)
        let joined = try await persistence.reserveRegistration(book: duplicateBook, job: duplicateJob)
        #expect(joined.disposition == .joinedPending)
        #expect(joined.book.id == book.id)
        #expect(joined.token == job.token)

        let stale = BookMaterializationToken(ownerID: job.token.ownerID, accountGeneration: job.token.accountGeneration, bookID: book.id, attemptID: UUID())
        #expect(try await persistence.transition(token: stale, from: .registered, to: .copying) == false)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .copying))
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: UUID()) == nil)
    }

    @Test("deterministic identity collision is surfaced for fresh-ID retry")
    func deterministicIdentityCollisionCanBeRetried() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let first = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: first.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: first)

        var collisionBook = book
        collisionBook.title = "Different edition with same deterministic identity"
        let collision = makeJob(book: collisionBook, sha256: "bbcc")
        do {
            _ = try await persistence.reserveRegistration(book: collisionBook, job: collision)
            Issue.record("an occupied deterministic ID unexpectedly reserved")
        } catch BookImportPersistenceError.bookIDOccupied {
        }

        let retryBook = Book(
            id: UUID(),
            userId: collisionBook.userId,
            title: collisionBook.title,
            author: collisionBook.author,
            formatType: collisionBook.formatType,
            addedAt: collisionBook.addedAt,
            openedAt: collisionBook.openedAt,
            fileURL: "books/retry.pdf",
            coverPath: collisionBook.coverPath,
            positionId: collisionBook.positionId,
            conversationId: collisionBook.conversationId,
            chapterIndexContentVersion: collisionBook.chapterIndexContentVersion
        )
        let retry = makeJob(book: retryBook, sha256: collision.expectedSHA256)
        let retried = try await persistence.reserveRegistration(book: retryBook, job: retry)
        #expect(retried.disposition == .registered)
        #expect(retried.book.id == retryBook.id)
    }

    @Test("unpublished source mismatch rollback deletes only the exact registered token")
    func discardUnpublishedRegistrationCAS() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let books = SwiftDataBookStore(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)

        let stale = BookMaterializationToken(ownerID: job.token.ownerID, accountGeneration: job.token.accountGeneration, bookID: book.id, attemptID: UUID())
        #expect(!(try await persistence.discardUnpublishedRegistration(token: stale)))
        #expect(try await persistence.discardUnpublishedRegistration(token: job.token))
        #expect(try await books.book(book.id) == nil)
        #expect(try await persistence.pendingMaterializationForDeletionCleanup(bookID: book.id, ownerID: book.userId) == nil)
    }

    @Test("inbound row delete retains attempt metadata until cleanup token CAS")
    func inboundDeleteRetainsPendingCleanupRecord() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let books = SwiftDataBookStore(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)

        let expected = try #require(await books.book(book.id))
        #expect(try await books.deleteIfUnchanged(book.id, matching: expected))
        #expect(try await books.book(book.id) == nil)

        let retained = try #require(await persistence.pendingMaterializationForDeletionCleanup(bookID: book.id, ownerID: book.userId))
        #expect(retained.token == job.token)
        let stale = BookMaterializationToken(ownerID: book.userId, accountGeneration: job.token.accountGeneration, bookID: book.id, attemptID: UUID())
        #expect(!(try await persistence.deletePendingMaterializationForDeletionCleanup(bookID: book.id, ownerID: book.userId, expectedToken: stale)))
        #expect(try await persistence.deletePendingMaterializationForDeletionCleanup(bookID: book.id, ownerID: book.userId, expectedToken: job.token))
        #expect(try await persistence.pendingMaterializationForDeletionCleanup(bookID: book.id, ownerID: book.userId) == nil)
    }

    @Test("managed commit and cover patch preserve newer book fields")
    func fieldPatchesPreserveNewerBookFields() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let books = SwiftDataBookStore(dbStore: db)
        let book = makeBook()
        let revision = UUID()
        let job = makeJob(book: book, destinationFileIdentifier: "managed-1", promotionRevision: revision)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .promoted))

        let newerOpenedAt = Date(timeIntervalSince1970: 900)
        let positionID = UUID()
        let conversationID = UUID()
        var newerBook = book
        newerBook.openedAt = newerOpenedAt
        newerBook.positionId = positionID
        newerBook.conversationId = conversationID
        try await books.upsert(newerBook)
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: job.expectedSHA256, version: ManagedFileVersion(byteCount: job.expectedByteCount, modificationDate: Date(timeIntervalSince1970: 800), fileIdentifier: "managed-1", materializationRevision: revision))

        #expect(try await persistence.commitManaged(token: job.token, fingerprint: fingerprint))
        #expect(try await persistence.patchCover(bookID: book.id, token: job.token, relativePath: "covers/new.jpg"))
        let restored = try #require(await books.book(book.id))
        #expect(restored.openedAt == newerOpenedAt)
        #expect(restored.positionId == positionID)
        #expect(restored.conversationId == conversationID)
        #expect(restored.coverPath == "covers/new.jpg")
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId) == fingerprint)
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: UUID()) == nil)
    }

    @Test("reservation revalidates a managed candidate under its write gate")
    func candidateRevalidation() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let inspector = FileManagedFileVersionInspector()
        let original = makeBook()
        let managedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-managed-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: managedRoot.appendingPathComponent("books", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: managedRoot) }
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: managedRoot, managedFileVersionInspector: inspector)
        let managedURL = managedRoot.appendingPathComponent(original.fileURL)
        try Data(repeating: 1, count: 42).write(to: managedURL)
        let revision = UUID()
        let observedVersion = try #require(try inspector.managedFileVersion(at: managedURL, materializationRevision: revision))
        let originalJob = makeJob(book: original, destinationFileIdentifier: observedVersion.fileIdentifier, promotionRevision: revision)
        try await persistence.setAccountAuthorization(ownerID: original.userId, generation: originalJob.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: original, job: originalJob)
        #expect(try await persistence.transition(token: originalJob.token, from: .registered, to: .promoted))
        let fingerprint = BookFileFingerprint(
            bookID: original.id,
            ownerID: original.userId,
            sha256: originalJob.expectedSHA256,
            version: observedVersion
        )
        #expect(try await persistence.commitManaged(token: originalJob.token, fingerprint: fingerprint))

        let selected = Book(id: UUID(), userId: original.userId, title: "Selected duplicate", formatType: .pdf, fileURL: "books/selected.pdf")
        let selectedJob = makeJob(book: selected)
        let candidate = BookImportCandidateSnapshot(bookID: original.id, ownerID: original.userId, relativePath: original.fileURL, sha256: fingerprint.sha256, fingerprintRevision: fingerprint.version.materializationRevision, observedManagedVersion: fingerprint.version, absoluteURL: managedURL)
        let noRootPersistence = SwiftDataBookImportPersistence(dbStore: db, managedFileVersionInspector: inspector)
        do {
            _ = try await noRootPersistence.reserveRegistration(book: selected, job: selectedJob, candidate: candidate)
            Issue.record("candidate matched without a configured managed root")
        } catch SwiftDataBookImportPersistence.PersistenceError.staleCandidate {
        }
        let matched = try await persistence.reserveRegistration(book: selected, job: selectedJob, candidate: candidate)
        #expect(matched.disposition == .alreadyManaged)
        #expect(matched.book.id == original.id)
        #expect(matched.token == nil)

        let decoyURL = managedRoot.appendingPathComponent("books/decoy.epub")
        try Data(repeating: 1, count: Int(originalJob.expectedByteCount)).write(to: decoyURL)
        let unrelatedURLCandidate = BookImportCandidateSnapshot(bookID: original.id, ownerID: original.userId, relativePath: original.fileURL, sha256: fingerprint.sha256, fingerprintRevision: fingerprint.version.materializationRevision, observedManagedVersion: fingerprint.version, absoluteURL: decoyURL)
        do {
            _ = try await persistence.reserveRegistration(book: selected, job: selectedJob, candidate: unrelatedURLCandidate)
            Issue.record("unrelated file URL unexpectedly matched the managed Book")
        } catch SwiftDataBookImportPersistence.PersistenceError.staleCandidate {
        }

        try Data(repeating: 2, count: Int(originalJob.expectedByteCount) + 1).write(to: managedURL)
        do {
            _ = try await persistence.reserveRegistration(book: selected, job: selectedJob, candidate: candidate)
            Issue.record("changed managed bytes unexpectedly matched the earlier candidate snapshot")
        } catch SwiftDataBookImportPersistence.PersistenceError.staleCandidate {
        }
    }

    @Test("non-ready materialization cannot be cached or reused as a managed candidate")
    func pendingMaterializationBlocksManagedReuse() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let inspector = FileManagedFileVersionInspector()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-managed-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root, managedFileVersionInspector: inspector)
        let book = makeBook()
        let managedURL = root.appendingPathComponent(book.fileURL)
        try Data(repeating: 1, count: 42).write(to: managedURL)
        let revision = UUID()
        let version = try #require(try inspector.managedFileVersion(at: managedURL, materializationRevision: revision))
        let job = makeJob(book: book)
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: job.expectedSHA256, version: version)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        try await db.write { context in context.insert(BookFileFingerprintEntity(fingerprint)) }

        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedRelativePath: book.fileURL, expectedVersion: version) == false)
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId) == nil)

        let selected = Book(id: UUID(), userId: book.userId, title: "Selected duplicate", formatType: .epub, fileURL: "books/selected.epub")
        let selectedJob = makeJob(book: selected)
        let candidate = BookImportCandidateSnapshot(bookID: book.id, ownerID: book.userId, relativePath: book.fileURL, sha256: fingerprint.sha256, fingerprintRevision: version.materializationRevision, observedManagedVersion: version, absoluteURL: managedURL)
        do {
            _ = try await persistence.reserveRegistration(book: selected, job: selectedJob, candidate: candidate)
            Issue.record("in-flight materialization was reused as a managed candidate")
        } catch SwiftDataBookImportPersistence.PersistenceError.staleCandidate {
        }
    }

    @Test("ready provenance mismatch invalidates digest cache and candidate reservation")
    func readyProvenanceMismatchIsRejected() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let inspector = FileManagedFileVersionInspector()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-managed-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root, managedFileVersionInspector: inspector)
        let book = makeBook()
        let managedURL = root.appendingPathComponent(book.fileURL)
        try Data(repeating: 1, count: 42).write(to: managedURL)
        let revision = UUID()
        let version = try #require(try inspector.managedFileVersion(at: managedURL, materializationRevision: revision))
        let job = makeJob(book: book, destinationFileIdentifier: version.fileIdentifier, promotionRevision: revision)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .promoted))
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: job.expectedSHA256, version: version)
        #expect(try await persistence.commitManaged(token: job.token, fingerprint: fingerprint))
        try await db.write { context in
            var descriptor = FetchDescriptor<PendingBookMaterializationEntity>()
            descriptor.predicate = #Predicate { $0.bookID == book.id }
            try #require(context.fetch(descriptor).first).destinationFileIdentifier = "different-file"
        }
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedRelativePath: book.fileURL, expectedVersion: version) == false)
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId) == nil)
        let selected = Book(id: UUID(), userId: book.userId, title: "Selected duplicate", formatType: .epub, fileURL: "books/selected.epub")
        let candidate = BookImportCandidateSnapshot(bookID: book.id, ownerID: book.userId, relativePath: book.fileURL, sha256: fingerprint.sha256, fingerprintRevision: revision, observedManagedVersion: fingerprint.version, absoluteURL: managedURL)
        do {
            _ = try await persistence.reserveRegistration(book: selected, job: makeJob(book: selected), candidate: candidate)
            Issue.record("ready job with mismatched file provenance was reused")
        } catch SwiftDataBookImportPersistence.PersistenceError.staleCandidate {
        }
    }

    @Test("failed, cancelled, and drained paused digest jobs keep their canonical book ID")
    func terminalJobsDoNotCreateDuplicateBooks() async throws {
        for terminalPhase in [BookMaterializationPhase.failed, .cancelled, .paused] {
            let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
            let persistence = SwiftDataBookImportPersistence(dbStore: db)
            let book = makeBook()
            let job = makeJob(book: book)
            try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
            _ = try await persistence.reserveRegistration(book: book, job: job)
            #expect(try await persistence.transition(token: job.token, from: .registered, to: terminalPhase))

            let duplicate = Book(id: UUID(), userId: book.userId, title: "Reselected", formatType: .pdf, fileURL: "books/reselected.pdf")
            let duplicateJob = makeJob(book: duplicate)
            let reservation = try await persistence.reserveRegistration(book: duplicate, job: duplicateJob)
            #expect(reservation.disposition == .retryRequired)
            #expect(reservation.book.id == book.id)
            #expect(reservation.token == job.token)

            let retryJob = makeJob(book: Book(id: book.id, userId: book.userId, title: book.title, formatType: book.formatType, fileURL: book.fileURL), attemptID: UUID())
            let notRetired = try await persistence.joinOrRetryPending(ownerID: book.userId, sha256: job.expectedSHA256, newSource: retryJob)
            #expect(notRetired?.disposition == .retryRequired)
            let retired = RetiredBookMaterializationAttempt(token: job.token)
            let retried = try await persistence.joinOrRetryPending(ownerID: book.userId, sha256: job.expectedSHA256, newSource: retryJob, retiredAttempt: retired)
            #expect(retried?.disposition == .retried)
            #expect(retried?.book.id == book.id)
            #expect(retried?.token == retryJob.token)
            #expect(try await db.read { context in try context.fetch(FetchDescriptor<BookEntity>()).count } == 1)
        }
    }

    @Test("stale attempts cannot refresh a recovered bookmark")
    func bookmarkRefreshCAS() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: 7, bookID: book.id, attemptID: UUID()),
            sourceKind: .securityScopedOriginal,
            sourceBookmark: Data([1]),
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 100), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: "aabb", expectedByteCount: 42,
            stagingRelativePath: "Imports/attempt/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: 7)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        let stale = BookMaterializationToken(ownerID: book.userId, accountGeneration: 7, bookID: book.id, attemptID: UUID())
        #expect(try await persistence.refreshSourceBookmark(token: stale, refreshedData: Data([2])) == false)
        #expect(try await persistence.refreshSourceBookmark(token: job.token, refreshedData: Data([3, 4])))
        let refreshed = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(refreshed.sourceBookmark == Data([3, 4]))
    }

    @Test("recovery rejects nonrecoverable phases and artifact mismatches")
    func recoveryCAS() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        let artifact = VerifiedBookArtifacts(sha256: job.expectedSHA256, byteCount: job.expectedByteCount, stagingRelativePath: job.stagingRelativePath, destinationRelativePath: job.destinationRelativePath, preparedFileIdentifier: nil, destinationFileIdentifier: nil, promotionRevision: nil)

        let mismatchedArtifact = VerifiedBookArtifacts(sha256: "different", byteCount: artifact.byteCount, stagingRelativePath: artifact.stagingRelativePath, destinationRelativePath: artifact.destinationRelativePath, preparedFileIdentifier: artifact.preparedFileIdentifier, destinationFileIdentifier: artifact.destinationFileIdentifier, promotionRevision: artifact.promotionRevision)
        #expect(try await persistence.adoptRecovery(expectedToken: job.token, currentOwnerID: book.userId, currentGeneration: job.token.accountGeneration, newAttemptID: UUID(), verifiedArtifacts: mismatchedArtifact) == nil)
        let recovered = try await persistence.adoptRecovery(expectedToken: job.token, currentOwnerID: book.userId, currentGeneration: job.token.accountGeneration, newAttemptID: UUID(), verifiedArtifacts: artifact)
        #expect(recovered?.bookID == book.id)
    }

    @Test("invalid old-generation artifacts quarantine into same-book picker retry")
    func quarantineRecoveryPermitsPickerRetry() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        let activeGeneration = job.token.accountGeneration + 1
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .copying))
        let prepared = VerifiedBookArtifacts(
            sha256: job.expectedSHA256,
            byteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath,
            destinationRelativePath: job.destinationRelativePath,
            preparedFileIdentifier: "bad-stage",
            destinationFileIdentifier: nil,
            promotionRevision: nil
        )
        #expect(try await persistence.recordPrepared(token: job.token, artifacts: prepared))
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: activeGeneration)

        let rotatedID = UUID()
        let quarantined = try #require(await persistence.quarantineRecovery(
            expectedToken: job.token,
            currentOwnerID: book.userId,
            currentGeneration: activeGeneration,
            newAttemptID: rotatedID
        ))
        let paused = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(paused.token == quarantined)
        #expect(paused.phase == .paused)
        #expect(paused.preparedFileIdentifier == nil)
        #expect(paused.retryableErrorCode == "recovery_artifact_invalid")

        let retryID = UUID()
        let retry = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: activeGeneration, bookID: book.id, attemptID: retryID),
            sourceKind: .securityScopedOriginal,
            sourceBookmark: Data([7, 6, 5]),
            ownedSourceRelativePath: nil,
            sourceVersion: job.sourceVersion,
            expectedSHA256: job.expectedSHA256,
            expectedByteCount: job.expectedByteCount,
            stagingRelativePath: "Imports/\(retryID.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
        let result = try #require(await persistence.joinOrRetryPending(
            ownerID: book.userId,
            sha256: job.expectedSHA256,
            newSource: retry,
            retiredAttempt: RetiredBookMaterializationAttempt(token: quarantined)
        ))
        #expect(result.disposition == .retried)
        #expect(result.book.id == book.id)
        #expect(result.token == retry.token)
    }

    @Test("waiting recovery jobs reauthorize across successive same-owner generations without rotating")
    func waitingRecoveryReauthorizationIsIdempotent() async throws {
        for marker in ["recovery_artifact_invalid", "recovery_source_unavailable"] {
            let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
            let persistence = SwiftDataBookImportPersistence(dbStore: db)
            let book = makeBook()
            let oldJob = makeJob(book: book)
            let quarantinedGeneration: UInt64 = 8
            try await persistence.setAccountAuthorization(ownerID: book.userId, generation: oldJob.token.accountGeneration)
            _ = try await persistence.reserveRegistration(book: book, job: oldJob)
            var waitingToken: BookMaterializationToken

            if marker == "recovery_artifact_invalid" {
                #expect(try await persistence.transition(token: oldJob.token, from: .registered, to: .copying))
                let artifact = VerifiedBookArtifacts(
                    sha256: oldJob.expectedSHA256, byteCount: oldJob.expectedByteCount,
                    stagingRelativePath: oldJob.stagingRelativePath, destinationRelativePath: oldJob.destinationRelativePath,
                    preparedFileIdentifier: "invalid", destinationFileIdentifier: nil, promotionRevision: nil
                )
                #expect(try await persistence.recordPrepared(token: oldJob.token, artifacts: artifact))
                try await persistence.setAccountAuthorization(ownerID: book.userId, generation: quarantinedGeneration)
                waitingToken = try #require(await persistence.quarantineRecovery(
                    expectedToken: oldJob.token, currentOwnerID: book.userId,
                    currentGeneration: quarantinedGeneration, newAttemptID: UUID()
                ))
            } else {
                try await persistence.setAccountAuthorization(ownerID: book.userId, generation: quarantinedGeneration)
                let artifacts = VerifiedBookArtifacts(
                    sha256: oldJob.expectedSHA256, byteCount: oldJob.expectedByteCount,
                    stagingRelativePath: oldJob.stagingRelativePath, destinationRelativePath: oldJob.destinationRelativePath,
                    preparedFileIdentifier: nil, destinationFileIdentifier: nil, promotionRevision: nil
                )
                waitingToken = try #require(await persistence.adoptRecovery(
                    expectedToken: oldJob.token, currentOwnerID: book.userId,
                    currentGeneration: quarantinedGeneration, newAttemptID: UUID(), verifiedArtifacts: artifacts
                ))
            }

            for generation in [UInt64(9), UInt64(10)] {
                try await persistence.setAccountAuthorization(ownerID: book.userId, generation: generation)
                let authorized = try #require(await persistence.reauthorizeWaitingRecovery(
                    expectedToken: waitingToken, currentOwnerID: book.userId, currentGeneration: generation
                ))
                #expect(authorized.accountGeneration == generation)
                #expect(authorized.attemptID == waitingToken.attemptID)
                waitingToken = authorized
                let pending = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
                #expect(pending.token == authorized)
                #expect(pending.retryableErrorCode == marker)
            }
            #expect(try #require(await SwiftDataBookStore(dbStore: db).book(book.id)).id == book.id)
        }
    }

    @Test("prepared and promotion provenance is written with attempt-token CAS")
    func promotionProvenanceCAS() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .copying))

        let prepared = VerifiedBookArtifacts(
            sha256: job.expectedSHA256,
            byteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath,
            destinationRelativePath: job.destinationRelativePath,
            preparedFileIdentifier: "staged-inode",
            destinationFileIdentifier: nil,
            promotionRevision: nil
        )
        #expect(try await persistence.recordPrepared(token: job.token, artifacts: prepared))
        let revision = UUID()
        let stale = BookMaterializationToken(ownerID: job.token.ownerID, accountGeneration: job.token.accountGeneration, bookID: job.token.bookID, attemptID: UUID())
        #expect(try await persistence.claimPromotion(token: stale, preparedFileIdentifier: "staged-inode", promotionRevision: revision) == false)
        #expect(try await persistence.claimPromotion(token: job.token, preparedFileIdentifier: "staged-inode", promotionRevision: revision))

        let claimed = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(claimed.phase == .promoting)
        #expect(claimed.preparedFileIdentifier == "staged-inode")
        #expect(claimed.promotionRevision == revision)
        #expect(try await persistence.recordPromoted(token: job.token, preparedFileIdentifier: "staged-inode", destinationFileIdentifier: "other-inode", promotionRevision: revision) == false)
        #expect(try await persistence.recordPromoted(token: job.token, preparedFileIdentifier: "staged-inode", destinationFileIdentifier: "staged-inode", promotionRevision: revision))

        let promoted = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(promoted.phase == .promoted)
        #expect(promoted.destinationFileIdentifier == "staged-inode")
        #expect(promoted.preparedFileIdentifier == "staged-inode")
        #expect(promoted.promotionRevision == revision)
    }

    @Test("recovery adopts same-owner artifacts across account generations")
    func recoveryAdoptsAcrossGeneration() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        let activeGeneration: UInt64 = 8
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .copying))
        let artifact = VerifiedBookArtifacts(
            sha256: job.expectedSHA256,
            byteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath,
            destinationRelativePath: job.destinationRelativePath,
            preparedFileIdentifier: "recovery-inode",
            destinationFileIdentifier: nil,
            promotionRevision: nil
        )
        #expect(try await persistence.recordPrepared(token: job.token, artifacts: artifact))
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: activeGeneration)

        let visibleToRecovery = try #require(await persistence.pendingMaterializationForRecovery(
            bookID: book.id,
            ownerID: book.userId,
            currentGeneration: activeGeneration
        ))
        #expect(visibleToRecovery.token == job.token)
        await #expect(throws: SwiftDataBookImportPersistence.PersistenceError.unauthorized) {
            try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)
        }

        let adopted = try #require(await persistence.adoptRecovery(
            expectedToken: job.token,
            currentOwnerID: book.userId,
            currentGeneration: activeGeneration,
            newAttemptID: UUID(),
            verifiedArtifacts: artifact
        ))
        #expect(adopted.accountGeneration == activeGeneration)
        let reauthorized = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(reauthorized.token == adopted)
        #expect(reauthorized.phase == .prepared)
        #expect(reauthorized.preparedFileIdentifier == "recovery-inode")
    }

    @Test("ready managed source is reauthorized after same-owner relogin")
    func readyManagedSourceReauthorization() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-ready-relogin-\(UUID().uuidString)", isDirectory: true)
        let book = makeBook()
        let seedJob = makeJob(book: book)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(book.fileURL)
        try Data(repeating: 7, count: Int(seedJob.expectedByteCount)).write(to: fileURL)
        let inspector = FileManagedFileVersionInspector()
        let revision = UUID()
        let version = try #require(try inspector.managedFileVersion(at: fileURL, materializationRevision: revision))
        let job = makeJob(book: book, destinationFileIdentifier: version.fileIdentifier, promotionRevision: revision)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root, managedFileVersionInspector: inspector)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: job.expectedSHA256, version: version)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .promoted))
        #expect(try await persistence.commitManaged(token: job.token, fingerprint: fingerprint))

        let nextGeneration = job.token.accountGeneration + 1
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: nextGeneration)
        await #expect(throws: SwiftDataBookImportPersistence.PersistenceError.unauthorized) {
            try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)
        }
        #expect(try await persistence.reauthorizeReadyManagedSource(bookID: book.id, ownerID: book.userId, generation: nextGeneration, fingerprint: fingerprint))
        let currentJob = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(currentJob.phase == .ready)
        #expect(currentJob.token.bookID == book.id)
        #expect(currentJob.token.accountGeneration == nextGeneration)
        #expect(currentJob.expectedSHA256 == fingerprint.sha256)
        #expect(currentJob.promotionRevision == revision)
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId) == fingerprint)
    }

    @Test("legacy managed fingerprint aligns reading revision and reauthorizes scoped writes without a pending job")
    func legacyManagedSourceAuthorizationUsesVerifiedRevision() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-legacy-auth-\(UUID().uuidString)", isDirectory: true)
        let book = makeBook()
        let legacyGeneration: UInt64 = 7
        let currentGeneration: UInt64 = 8
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managedURL = root.appendingPathComponent(book.fileURL)
        try Data(repeating: 3, count: 42).write(to: managedURL)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await SwiftDataBookStore(dbStore: db).upsert(book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: legacyGeneration)
        let staleRevision = UUID()
        try await persistence.setBookReadingAuthorization(
            bookID: book.id,
            ownerID: book.userId,
            generation: legacyGeneration,
            contentRevision: staleRevision,
            tombstoned: false
        )
        let verifiedRevision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: verifiedRevision))
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: "verified-legacy-content", version: version)

        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedRelativePath: book.fileURL, expectedVersion: version))
        let seededAuth = try await db.read { context in
            let rows = try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>(predicate: #Predicate { $0.bookID == book.id }))
            return rows.first.map { ($0.accountGenerationBits, $0.contentRevision, $0.verifiedContentDigest) }
        }
        #expect(seededAuth?.0 == Int64(bitPattern: legacyGeneration))
        #expect(seededAuth?.1 == verifiedRevision)
        #expect(seededAuth?.2 == fingerprint.sha256)

        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: currentGeneration)
        #expect(try await persistence.reauthorizeReadyManagedSource(
            bookID: book.id,
            ownerID: book.userId,
            generation: currentGeneration,
            fingerprint: fingerprint
        ))
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId) == nil)

        let permit = BookReadingPermit(ownerID: book.userId, accountGeneration: currentGeneration, bookID: book.id, contentRevision: verifiedRevision)
        let source = BookSourceAccessPermit()
        let sourceEffects = BookSourceEffectAuthority()
        sourceEffects.register(source)
        let conversation = Conversation(userId: book.userId, bookId: book.id, title: "Legacy scoped write")
        try await BookScopedMutationStore(dbStore: db).upsert(
            conversation,
            authority: .book(permit),
            originatingSource: source,
            sourceEffects: sourceEffects
        )
        #expect(try await SwiftDataConversationStore(dbStore: db).conversation(conversation.id) == conversation)
    }

    @Test("server acceptance is committed only for the current verified owner generation and revision")
    func serverAcceptanceUsesAuthorizationCAS() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-server-acceptance-\(UUID().uuidString)", isDirectory: true)
        let book = makeBook()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("books", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(book.fileURL)
        try Data(repeating: 9, count: 24).write(to: file)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        let generation: UInt64 = 4
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: file, materializationRevision: revision))
        let sha = String(repeating: "a", count: 64)
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: sha, version: version)
        try await SwiftDataBookStore(dbStore: db).upsert(book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: book.userId, generation: generation, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedRelativePath: book.fileURL, expectedVersion: version))
        let acceptance = BookServerAcceptance(sha256: sha, acceptedOperationID: UUID(), acceptedAt: Date())

        #expect(try await persistence.recordServerAcceptance(bookID: book.id, ownerID: book.userId, expectedGeneration: generation, expectedContentRevision: revision, acceptance: acceptance))
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId)?.serverAcceptance == acceptance)
        #expect(!(try await persistence.recordServerAcceptance(bookID: book.id, ownerID: book.userId, expectedGeneration: generation + 1, expectedContentRevision: revision, acceptance: acceptance)))
        #expect(!(try await persistence.recordServerAcceptance(bookID: book.id, ownerID: book.userId, expectedGeneration: generation, expectedContentRevision: UUID(), acceptance: acceptance)))
    }

    @Test("unprepared recovery rotates attempt and enables same-book picker retry")
    func unpreparedRecoveryThenManualRetry() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let oldJob = makeJob(book: book)
        let activeGeneration = oldJob.token.accountGeneration + 1
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: oldJob.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: oldJob)
        #expect(try await persistence.transition(token: oldJob.token, from: .registered, to: .copying))
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: activeGeneration)

        let visible = try #require(await persistence.pendingMaterializationForRecovery(bookID: book.id, ownerID: book.userId, currentGeneration: activeGeneration))
        let unprepared = VerifiedBookArtifacts(
            sha256: visible.expectedSHA256,
            byteCount: visible.expectedByteCount,
            stagingRelativePath: visible.stagingRelativePath,
            destinationRelativePath: visible.destinationRelativePath,
            preparedFileIdentifier: nil,
            destinationFileIdentifier: nil,
            promotionRevision: nil
        )
        let recoveredAttempt = UUID()
        let recovered = try #require(await persistence.adoptRecovery(
            expectedToken: oldJob.token,
            currentOwnerID: book.userId,
            currentGeneration: activeGeneration,
            newAttemptID: recoveredAttempt,
            verifiedArtifacts: unprepared
        ))
        let adopted = try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId))
        #expect(adopted.token == recovered)
        #expect(adopted.phase == .paused)
        #expect(adopted.stagingRelativePath == "Imports/\(recoveredAttempt.uuidString)/content.partial")
        #expect(adopted.expectedSHA256 == oldJob.expectedSHA256)
        #expect(adopted.sourceBookmark == oldJob.sourceBookmark)
        #expect(try #require(await SwiftDataBookStore(dbStore: db).book(book.id)).fileURL == book.fileURL)

        let retryID = UUID()
        let retry = PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: activeGeneration, bookID: book.id, attemptID: retryID),
            sourceKind: .securityScopedOriginal,
            sourceBookmark: Data([9, 8, 7]),
            ownedSourceRelativePath: nil,
            sourceVersion: oldJob.sourceVersion,
            expectedSHA256: oldJob.expectedSHA256,
            expectedByteCount: oldJob.expectedByteCount,
            stagingRelativePath: "Imports/\(retryID.uuidString)/content.partial",
            destinationRelativePath: oldJob.destinationRelativePath,
            phase: .registered
        )
        let retried = try #require(await persistence.joinOrRetryPending(
            ownerID: book.userId,
            sha256: oldJob.expectedSHA256,
            newSource: retry,
            retiredAttempt: RetiredBookMaterializationAttempt(token: recovered)
        ))
        #expect(retried.disposition == .retried)
        #expect(retried.book.id == book.id)
        #expect(retried.token == retry.token)
        #expect(try #require(await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)).phase == .registered)
    }

    @Test("account purge removes import state")
    func purgeRemovesImportState() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let persistence = SwiftDataBookImportPersistence(dbStore: db)
        let book = makeBook()
        let job = makeJob(book: book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)

        try await db.write { context in
            context.insert(AccountMutationAuthorizationEntity(ownerID: UUID(), generation: 1))
        }
        try await db.purgeAll()
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId) == nil)
        let counts = try await db.read { context in
            (try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).count,
             try context.fetch(FetchDescriptor<PendingBookMaterializationEntity>()).count,
             try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>()).count,
             try context.fetch(FetchDescriptor<AccountMutationAuthorizationEntity>()).count)
        }
        #expect(counts == (0, 0, 0, 0))
    }

    private func makeBook() -> Book {
        Book(userId: UUID(), title: "Imported", formatType: .epub, fileURL: "books/imported.epub")
    }

    private func makeJob(book: Book, attemptID: UUID = UUID(), sha256: String = "aabb", destinationFileIdentifier: String? = nil, promotionRevision: UUID? = nil) -> PendingBookMaterialization {
        PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: 7, bookID: book.id, attemptID: attemptID),
            sourceKind: .ownedStaging,
            sourceBookmark: nil,
            ownedSourceRelativePath: "staging/source.epub",
            sourceVersion: ManagedFileVersion(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 100), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: sha256,
            expectedByteCount: 42,
            stagingRelativePath: "staging/import.part",
            destinationRelativePath: book.fileURL,
            phase: .registered,
            destinationFileIdentifier: destinationFileIdentifier,
            promotionRevision: promotionRevision
        )
    }

    private enum TestFailure: Error { case expected }
}
