@testable import rishi
import CryptoKit
import Foundation
import SwiftData
import Testing

private actor LegacyBackfillCallCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

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

    @Test("a legacy managed book is fingerprinted, reauthorized, and readable on first open")
    func legacyManagedBookBackfillCreatesFingerprintAndReadingAuthorization() async throws {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let userID = UUID()
        let generation: UInt64 = 17
        let bookID = UUID()
        let relativePath = "Books/\(bookID.uuidString)/legacy.epub"
        let url = root.appendingPathComponent(relativePath)
        let bytes = Data("actual legacy managed EPUB bytes".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)

        let books = SwiftDataBookStore(dbStore: db)
        let book = Book(id: bookID, userId: userID, title: "Legacy", formatType: .epub, fileURL: relativePath)
        try await books.upsert(book)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await persistence.setAccountAuthorization(ownerID: userID, generation: generation)
        #expect(try await persistence.fingerprint(bookID: bookID, ownerID: userID) == nil)
        #expect(try await persistence.readingPermit(bookID: bookID, ownerID: userID, generation: generation) == nil)
        #expect(try await persistence.pendingMaterialization(bookID: bookID, ownerID: userID) == nil)

        let storage = BookFileStorage(
            rootURL: root,
            bookStore: books,
            coverExtractors: [:],
            fingerprintPersistence: persistence,
            fingerprintAccountGeneration: { generation }
        )
        let backfillCalls = LegacyBackfillCallCounter()
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { userID },
            backfillManagedFingerprintIfNeeded: { candidate in
                guard candidate.id == book.id, candidate.userId == userID else { return false }
                await backfillCalls.record()
                guard let verified = await storage.cacheVerifiedManagedFile(for: candidate) else { return false }
                return verified.fingerprintPersisted
            },
            managedURL: { storage.absoluteFileURL(for: $0) }
        )

        let lease = try await registry.acquireReadableSource(for: book)
        let fingerprint = try #require(await persistence.fingerprint(bookID: bookID, ownerID: userID))
        let expectedDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(lease.url == url)
        #expect(fingerprint.sha256 == expectedDigest)
        #expect(lease.owner.access == .account(BookReadingPermit(
            ownerID: userID,
            accountGeneration: generation,
            bookID: bookID,
            contentRevision: fingerprint.version.materializationRevision
        )))
        let persistedPermit = try #require(try await persistence.readingPermit(
            forManagedFingerprint: fingerprint,
            expectedRelativePath: relativePath,
            generation: generation
        ))
        #expect(persistedPermit.ownerID == userID)
        #expect(persistedPermit.accountGeneration == generation)
        #expect(persistedPermit.bookID == bookID)
        #expect(await backfillCalls.count == 1)

        let reopened = try await registry.acquireReadableSource(for: book)
        #expect(reopened.url == url)
        #expect(await backfillCalls.count == 1)
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

        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: job.token.accountGeneration, expectedRelativePath: book.fileURL, expectedVersion: version) == false)
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
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: job.token.accountGeneration, expectedRelativePath: book.fileURL, expectedVersion: version) == false)
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
            let stillRetryRequired = try await persistence.joinOrRetryPending(ownerID: book.userId, sha256: job.expectedSHA256, newSource: retryJob, retiredAttempt: retired)
            #expect(stillRetryRequired?.disposition == .retryRequired)
            #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)?.token == job.token)
            let expectation = try #require(await persistence.retryExpectation(
                bookID: book.id, ownerID: book.userId,
                accountPermit: AccountMutationPermit(ownerID: book.userId, accountGeneration: job.token.accountGeneration)
            ))
            let retried = try await persistence.retryPendingMaterialization(
                expected: expectation,
                accountPermit: AccountMutationPermit(ownerID: book.userId, accountGeneration: job.token.accountGeneration),
                newSource: retryJob,
                verifiedSourceSHA256: job.expectedSHA256,
                verifiedSourceByteCount: job.expectedByteCount,
                verifiedSourceVersion: retryJob.sourceVersion,
                retiredAttempt: retired
            )
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
        let retired = RetiredBookMaterializationAttempt(token: quarantined)
        let result = try #require(await persistence.joinOrRetryPending(
            ownerID: book.userId,
            sha256: job.expectedSHA256,
            newSource: retry,
            retiredAttempt: retired
        ))
        #expect(result.disposition == .retryRequired)
        #expect(result.token == quarantined)
        let permit = AccountMutationPermit(ownerID: book.userId, accountGeneration: activeGeneration)
        let expectation = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: book.userId, accountPermit: permit))
        let retried = try #require(await persistence.retryPendingMaterialization(
            expected: expectation, accountPermit: permit, newSource: retry,
            verifiedSourceSHA256: job.expectedSHA256, verifiedSourceByteCount: job.expectedByteCount,
            verifiedSourceVersion: retry.sourceVersion, retiredAttempt: retired
        ))
        #expect(retried.disposition == .retried)
        #expect(retried.book.id == book.id)
        #expect(retried.token == retry.token)
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
        let originalBytes = Data(repeating: 7, count: Int(seedJob.expectedByteCount))
        try originalBytes.write(to: fileURL)
        let digest = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        let inspector = FileManagedFileVersionInspector()
        let revision = UUID()
        let version = try #require(try inspector.managedFileVersion(at: fileURL, materializationRevision: revision))
        let job = makeJob(book: book, sha256: digest, destinationFileIdentifier: version.fileIdentifier, promotionRevision: revision)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root, managedFileVersionInspector: inspector)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: job.token.accountGeneration)
        _ = try await persistence.reserveRegistration(book: book, job: job)
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: job.expectedSHA256, version: version)
        #expect(try await persistence.transition(token: job.token, from: .registered, to: .promoted))
        #expect(try await persistence.commitManaged(token: job.token, fingerprint: fingerprint))
        let originalPermit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: job.token.accountGeneration))

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
        let managedPermit = try #require(try await persistence.readingPermit(
            forManagedFingerprint: fingerprint,
            expectedRelativePath: book.fileURL,
            generation: nextGeneration
        ))
        #expect(managedPermit.contentRevision == originalPermit.contentRevision)
        #expect(managedPermit.contentRevision != fingerprint.version.materializationRevision)
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: job.token.accountGeneration) == nil)
        await #expect(throws: (any Error).self) { try await db.withReadingWrite(permit: originalPermit) { _ in () } }

        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { nextGeneration },
            currentOwnerID: { book.userId },
            managedURL: { _ in fileURL }
        )
        let managedSource = try #require(try await registry.managedSource(for: book))
        #expect(managedSource.readingPermit == managedPermit)
        #expect(managedSource.fingerprint.version.materializationRevision != managedSource.readingPermit.contentRevision)
        let managedLease = try await registry.acquireReadableSource(for: book)
        #expect(managedLease.access == .account(managedPermit))

        let acceptance = BookServerAcceptance(sha256: fingerprint.sha256, acceptedOperationID: UUID(), acceptedAt: .now)
        #expect(try await persistence.recordServerAcceptance(permit: managedPermit, expectedFingerprint: fingerprint, acceptance: acceptance))
        let mutations = BookScopedMutationStore(dbStore: db)
        try await mutations.upsert(Position(bookId: book.id, locator: "epubcfi(/6/2)"), permit: managedPermit)
        try await mutations.upsert(Bookmark(bookId: book.id, locator: "epubcfi(/6/4)"), permit: managedPermit)
        try await mutations.upsert(Highlight(bookId: book.id, locatorStart: "epubcfi(/6/6)", locatorEnd: "epubcfi(/6/8)", color: .yellow, text: "Saved"), permit: managedPermit)
        try await db.withSettingsWrite(permit: managedPermit) { _ in "dark" }
        #expect(try await SwiftDataPositionStore(dbStore: db).position(for: book.id)?.locator == "epubcfi(/6/2)")
        #expect(try await SwiftDataBookmarkStore(dbStore: db).bookmarks(for: book.id).count == 1)
        #expect(try await SwiftDataHighlightStore(dbStore: db).highlights(for: book.id).count == 1)
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: nextGeneration) == managedPermit)

        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { nextGeneration })
        lifecycle.retireBook(ownerID: book.userId, generation: nextGeneration, bookID: book.id)
        #expect(throws: BookSourceAccessError.revoked) {
            try managedLease.effectAuthority.admit(managedLease.sourceAccessPermit)
        }
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: nextGeneration) == managedPermit)
    }

    @Test("legacy cache preserves canonical revision across verified reseed and reauthorization")
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

        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: legacyGeneration, expectedRelativePath: book.fileURL, expectedVersion: version))
        let seededAuth = try await db.read { context in
            let rows = try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>(predicate: #Predicate { $0.bookID == book.id }))
            return rows.first.map { ($0.accountGenerationBits, $0.contentRevision, $0.verifiedContentDigest) }
        }
        #expect(seededAuth?.0 == Int64(bitPattern: legacyGeneration))
        #expect(seededAuth?.1 == staleRevision)
        #expect(seededAuth?.2 == fingerprint.sha256)
        let originalPermit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: legacyGeneration))
        let mutations = BookScopedMutationStore(dbStore: db)
        try await mutations.upsert(Position(bookId: book.id, locator: "legacy-position"), permit: originalPermit)
        try await mutations.upsert(Bookmark(bookId: book.id, locator: "legacy-bookmark"), permit: originalPermit)
        try await mutations.upsert(Highlight(bookId: book.id, locatorStart: "legacy-start", locatorEnd: "legacy-end", color: .yellow, text: "Legacy"), permit: originalPermit)
        try await db.withSettingsWrite(permit: originalPermit) { _ in "sepia" }

        let provenanceRevision = UUID()
        let provenanceVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: provenanceRevision))
        let reseededFingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: fingerprint.sha256, version: provenanceVersion)
        #expect(try await persistence.cacheManagedFingerprint(reseededFingerprint, expectedGeneration: legacyGeneration, expectedRelativePath: book.fileURL, expectedVersion: provenanceVersion))
        let reseededAuthRevision = try await db.read { context in
            try context.fetch(FetchDescriptor<BookReadingAuthorizationEntity>(predicate: #Predicate { $0.bookID == book.id })).first?.contentRevision
        }
        #expect(reseededAuthRevision == staleRevision)
        #expect(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: legacyGeneration) == originalPermit)

        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: currentGeneration)
        #expect(try await persistence.reauthorizeReadyManagedSource(
            bookID: book.id,
            ownerID: book.userId,
            generation: currentGeneration,
            fingerprint: reseededFingerprint
        ))
        #expect(try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId) == nil)

        let permit = BookReadingPermit(ownerID: book.userId, accountGeneration: currentGeneration, bookID: book.id, contentRevision: staleRevision)
        try await mutations.upsert(Position(bookId: book.id, locator: "current-position"), permit: permit)
        try await mutations.upsert(Bookmark(bookId: book.id, locator: "current-bookmark"), permit: permit)
        try await mutations.upsert(Highlight(bookId: book.id, locatorStart: "current-start", locatorEnd: "current-end", color: .blue, text: "Current"), permit: permit)
        try await db.withSettingsWrite(permit: permit) { _ in "dark" }
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
        #expect(try await SwiftDataPositionStore(dbStore: db).position(for: book.id)?.locator == "current-position")
        #expect(try await SwiftDataBookmarkStore(dbStore: db).bookmarks(for: book.id).count == 2)
        #expect(try await SwiftDataHighlightStore(dbStore: db).highlights(for: book.id).count == 2)
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
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: version))
        let acceptance = BookServerAcceptance(sha256: sha, acceptedOperationID: UUID(), acceptedAt: Date())
        let permit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: generation))

        #expect(try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: fingerprint, acceptance: acceptance))
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId)?.serverAcceptance == acceptance)
        let renewedAcceptance = BookServerAcceptance(sha256: sha, acceptedOperationID: UUID(), acceptedAt: Date().addingTimeInterval(1))
        #expect(try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: fingerprint, acceptance: renewedAcceptance))
        #expect(try await persistence.fingerprint(bookID: book.id, ownerID: book.userId)?.serverAcceptance == renewedAcceptance)
        let wrongGeneration = BookReadingPermit(ownerID: book.userId, accountGeneration: generation + 1, bookID: book.id, contentRevision: revision)
        let wrongRevision = BookReadingPermit(ownerID: book.userId, accountGeneration: generation, bookID: book.id, contentRevision: UUID())
        #expect(!(try await persistence.recordServerAcceptance(permit: wrongGeneration, expectedFingerprint: fingerprint, acceptance: acceptance)))
        #expect(!(try await persistence.recordServerAcceptance(permit: wrongRevision, expectedFingerprint: fingerprint, acceptance: acceptance)))

        try Data(repeating: 8, count: 24).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        let replacementVersion = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: file, materializationRevision: version.materializationRevision))
        let replacementDigest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        let replacement = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: replacementDigest, version: replacementVersion)
        #expect(try await persistence.cacheManagedFingerprint(replacement, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: replacementVersion))
        #expect(!(try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: fingerprint, acceptance: acceptance)))
        #expect(try await persistence.readingPermit(
            forManagedFingerprint: fingerprint,
            expectedRelativePath: book.fileURL,
            generation: generation
        ) == nil)
        let replacementPermit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: generation))
        #expect(try await persistence.readingPermit(
            forManagedFingerprint: replacement,
            expectedRelativePath: book.fileURL,
            generation: generation
        ) == replacementPermit)
        #expect(replacementPermit.contentRevision != permit.contentRevision)
        #expect(replacementPermit.contentRevision != replacementVersion.materializationRevision)
    }

    @Test("missing exact sample bytes reserve the existing Book ID and preserve reading records")
    func exactSampleRepairKeepsIdentityAndAcceptance() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = SwiftDataBookStore(dbStore: fixture.db)
        let bookmark = Bookmark(bookId: fixture.book.id, locator: "epubcfi(/6/2)", label: "Return here")
        let position = Position(bookId: fixture.book.id, locator: "epubcfi(/6/4)", percentComplete: 0.4)
        let highlight = Highlight(bookId: fixture.book.id, locatorStart: "epubcfi(/6/2)", locatorEnd: "epubcfi(/6/4)", color: .yellow, text: "Saved passage")
        try await SwiftDataBookmarkStore(dbStore: fixture.db).upsert(bookmark)
        try await SwiftDataPositionStore(dbStore: fixture.db).upsert(position)
        try await SwiftDataHighlightStore(dbStore: fixture.db).upsert(highlight)
        try FileManager.default.removeItem(at: fixture.managedURL)

        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        let request = sampleRepairRequest(fixture, job: job)
        let reservation = try await fixture.persistence.reserveSampleRepair(request)
        guard case let .reserved(registration) = reservation else {
            Issue.record("missing exact bytes did not reserve repair")
            return
        }
        #expect(registration.book.id == fixture.book.id)
        #expect(registration.token == job.token)
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId)?.token == job.token)

        let promotionRevision = UUID()
        #expect(try await fixture.persistence.transition(token: job.token, from: .registered, to: .copying))
        #expect(try await fixture.persistence.recordPrepared(token: job.token, artifacts: VerifiedBookArtifacts(
            sha256: job.expectedSHA256, byteCount: job.expectedByteCount,
            stagingRelativePath: job.stagingRelativePath, destinationRelativePath: job.destinationRelativePath,
            preparedFileIdentifier: "repaired-file", destinationFileIdentifier: nil, promotionRevision: nil
        )))
        #expect(try await fixture.persistence.claimPromotion(token: job.token, preparedFileIdentifier: "repaired-file", promotionRevision: promotionRevision))
        #expect(try await fixture.persistence.recordPromoted(token: job.token, preparedFileIdentifier: "repaired-file", destinationFileIdentifier: "repaired-file", promotionRevision: promotionRevision))
        let repairedFingerprint = BookFileFingerprint(
            bookID: fixture.book.id, ownerID: fixture.book.userId, sha256: fixture.fingerprint.sha256,
            version: ManagedFileVersion(byteCount: fixture.fingerprint.version.byteCount, modificationDate: Date(), fileIdentifier: "repaired-file", materializationRevision: promotionRevision)
        )
        #expect(try await fixture.persistence.commitManaged(token: job.token, fingerprint: repairedFingerprint))
        #expect(try await books.book(fixture.book.id) == fixture.book)
        #expect(try await SwiftDataBookmarkStore(dbStore: fixture.db).bookmark(bookmark.id) == bookmark)
        #expect(try await SwiftDataPositionStore(dbStore: fixture.db).position(for: fixture.book.id) == position)
        #expect(try await SwiftDataHighlightStore(dbStore: fixture.db).highlight(highlight.id) == highlight)
        #expect(try await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId)?.serverAcceptance == fixture.acceptance)
    }

    @Test("sample repair CAS rejects stale ownership, snapshots, provenance, generation and tombstones")
    func sampleRepairRejectsStaleClaims() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.managedURL)
        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)

        var foreignBook = fixture.book
        foreignBook.userId = UUID()
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
                expectedBook: foreignBook, expectedFingerprint: fixture.fingerprint,
                canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
            ))
        }

        var changedBook = fixture.book
        changedBook.title = "Updated title"
        try await SwiftDataBookStore(dbStore: fixture.db).upsert(changedBook)
        await #expect(throws: Error.self) { _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: job)) }
        try await SwiftDataBookStore(dbStore: fixture.db).upsert(fixture.book)

        let wrongDigest = BookFileFingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId, sha256: String(repeating: "f", count: 64), version: fixture.fingerprint.version)
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
                expectedBook: fixture.book, expectedFingerprint: wrongDigest,
                canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
            ))
        }
        let wrongRevision = BookFileFingerprint(
            bookID: fixture.book.id, ownerID: fixture.book.userId, sha256: fixture.fingerprint.sha256,
            version: ManagedFileVersion(
                byteCount: fixture.fingerprint.version.byteCount,
                modificationDate: fixture.fingerprint.version.modificationDate,
                fileIdentifier: fixture.fingerprint.version.fileIdentifier,
                materializationRevision: UUID()
            )
        )
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
                expectedBook: fixture.book, expectedFingerprint: wrongRevision,
                canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
            ))
        }
        let wrongLengthJob = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256, expectedByteCount: job.expectedByteCount + 1)
        await #expect(throws: Error.self) { _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: wrongLengthJob)) }
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
                expectedBook: fixture.book, expectedFingerprint: fixture.fingerprint,
                canonicalManagedURL: fixture.root.appendingPathComponent("books/decoy.epub"),
                expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
            ))
        }

        let wrongGeneration = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256, generation: job.token.accountGeneration + 1)
        await #expect(throws: Error.self) { _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: wrongGeneration)) }
        try await fixture.persistence.setBookReadingAuthorization(bookID: fixture.book.id, ownerID: fixture.book.userId, generation: job.token.accountGeneration, contentRevision: fixture.fingerprint.version.materializationRevision, tombstoned: true)
        await #expect(throws: Error.self) { _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: job)) }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)
    }

    @Test("sample repair accepts an alias-equivalent missing destination")
    func sampleRepairAcceptsMissingDestinationThroughRootAlias() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let aliasRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("sample-repair-alias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: aliasRoot) }
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: fixture.root)
        try FileManager.default.removeItem(at: fixture.managedURL)

        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        let aliasURL = aliasRoot.appendingPathComponent(fixture.book.fileURL)
        let result = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
            expectedBook: fixture.book,
            expectedFingerprint: fixture.fingerprint,
            canonicalManagedURL: aliasURL,
            expectedManagedFileVersion: nil,
            expectedPriorPendingToken: nil, job: job
        ))
        guard case let .reserved(registration) = result else {
            Issue.record("alias-equivalent missing destination did not reserve repair")
            return
        }
        #expect(registration.book.id == fixture.book.id)
        #expect(registration.token == job.token)
    }

    @Test("sample repair accepts a destination whose intermediate directories are absent")
    func sampleRepairAcceptsMissingIntermediateDirectories() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.managedURL)
        try FileManager.default.removeItem(at: fixture.managedURL.deletingLastPathComponent())

        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        let result = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: job))
        guard case let .reserved(registration) = result else {
            Issue.record("missing intermediate directories did not reserve repair")
            return
        }
        #expect(registration.book.id == fixture.book.id)
        #expect(registration.token == job.token)
    }

    @Test("sample repair rejects a missing destination below a symlinked parent outside the root")
    func sampleRepairRejectsExistingSymlinkParentEscape() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("sample-repair-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.managedURL)
        try FileManager.default.removeItem(at: fixture.managedURL.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: fixture.managedURL.deletingLastPathComponent(), withDestinationURL: outside)

        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: job))
        }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)
    }

    @Test("sample repair rejects dangling symlink parents and destination links")
    func sampleRepairRejectsDanglingSymlinkEscapes() async throws {
        for linkAtParent in [true, false] {
            let fixture = try await makeReadySample()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let outsideMissing = fixture.root.deletingLastPathComponent()
                .appendingPathComponent("sample-repair-missing-\(UUID().uuidString)")
            try FileManager.default.removeItem(at: fixture.managedURL)
            if linkAtParent {
                try FileManager.default.removeItem(at: fixture.managedURL.deletingLastPathComponent())
                try FileManager.default.createSymbolicLink(
                    at: fixture.managedURL.deletingLastPathComponent(),
                    withDestinationURL: outsideMissing
                )
            } else {
                try FileManager.default.createSymbolicLink(at: fixture.managedURL, withDestinationURL: outsideMissing)
            }

            let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
            await #expect(throws: Error.self) {
                _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: job))
            }
            #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)
        }
    }

    @Test("sample repair rejects traversal and absolute persisted destinations")
    func sampleRepairRejectsUnsafePersistedPaths() async throws {
        for unsafePath in ["books/../../outside.epub", "/tmp/outside.epub"] {
            let fixture = try await makeReadySample()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var unsafeBook = fixture.book
            unsafeBook.fileURL = unsafePath
            try await SwiftDataBookStore(dbStore: fixture.db).upsert(unsafeBook)
            let job = makeSampleRepairJob(book: unsafeBook, sha256: fixture.fingerprint.sha256)
            let canonicalURL = unsafePath.hasPrefix("/")
                ? URL(fileURLWithPath: unsafePath)
                : fixture.root.appendingPathComponent(unsafePath)
            let request = SampleRepairReservationRequest(
                expectedBook: unsafeBook,
                expectedFingerprint: fixture.fingerprint,
                canonicalManagedURL: canonicalURL,
                expectedManagedFileVersion: nil, expectedPriorPendingToken: nil,
                job: job
            )

            await #expect(throws: Error.self) {
                _ = try await fixture.persistence.reserveSampleRepair(request)
            }
            #expect(try await fixture.persistence.pendingMaterialization(bookID: unsafeBook.id, ownerID: unsafeBook.userId) == nil)
        }
    }

    @Test("sample repair does not reserve over present bytes or another active attempt")
    func sampleRepairRejectsPresentAndConcurrentAttempts() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        let present = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: first, expectedManagedFileVersion: fixture.fingerprint.version))
        guard case .alreadyManaged = present else {
            Issue.record("present verified bytes reserved a repair")
            return
        }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)

        try FileManager.default.removeItem(at: fixture.managedURL)
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: first)) else {
            Issue.record("first missing-byte attempt did not reserve")
            return
        }
        let second = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        await #expect(throws: Error.self) { _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: second, expectedPriorPendingToken: first.token)) }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId)?.token == first.token)
    }

    @Test("sample repair CAS refuses nil and stale-token observations without mutation")
    func sampleRepairCASRequiresExactObservedPriorToken() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.managedURL)
        let initialStoredFingerprint = try await fixture.db.read { context in
            try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).first?.value
        }
        let initialReadingPermit = try #require(
            try await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.book.userId, generation: 7)
        )
        let first = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(
            sampleRepairRequest(fixture, job: first, expectedPriorPendingToken: nil)
        ) else {
            Issue.record("nil-observed attempt did not reserve")
            return
        }
        let nilRace = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(
                sampleRepairRequest(fixture, job: nilRace, expectedPriorPendingToken: nil)
            )
        }
        #expect(try await fixture.persistence.transition(token: first.token, from: .registered, to: .copying))
        #expect(try await fixture.persistence.transition(token: first.token, from: .copying, to: .paused))

        let second = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(
            sampleRepairRequest(fixture, job: second, expectedPriorPendingToken: first.token)
        ) else {
            Issue.record("same-content replacement with the observed prior token did not reserve")
            return
        }
        let staleObservation = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(
                sampleRepairRequest(fixture, job: staleObservation, expectedPriorPendingToken: first.token)
            )
        }
        let retained = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(retained.token == second.token)
        #expect(retained.expectedSHA256 == second.expectedSHA256)
        let retainedFingerprint = try await fixture.db.read { context in
            try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).first?.value
        }
        #expect(retainedFingerprint == initialStoredFingerprint)
        #expect(try await SwiftDataBookStore(dbStore: fixture.db).book(fixture.book.id) == fixture.book)
        #expect(try await fixture.persistence.readingPermit(bookID: fixture.book.id, ownerID: fixture.book.userId, generation: 7) == initialReadingPermit)
    }

    @Test("sample repair parking is exact-token transactional and refuses tombstones")
    func sampleRepairParkingRequiresCurrentLiveReservation() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.managedURL)
        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(
            sampleRepairRequest(fixture, job: job, expectedPriorPendingToken: nil)
        ) else {
            Issue.record("missing sample did not reserve")
            return
        }

        #expect(await fixture.persistence.parkSampleRepair(book: fixture.book, token: job.token) == .parked)
        #expect(await fixture.persistence.parkSampleRepair(book: fixture.book, token: job.token) == .parked)
        let paused = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(paused.token == job.token)
        #expect(paused.phase == .paused)

        let staleToken = BookMaterializationToken(
            ownerID: job.token.ownerID, accountGeneration: job.token.accountGeneration,
            bookID: job.token.bookID, attemptID: UUID()
        )
        #expect(await fixture.persistence.parkSampleRepair(book: fixture.book, token: staleToken) == .supersededOrFenced)
        try await fixture.persistence.setBookReadingAuthorization(
            bookID: fixture.book.id, ownerID: fixture.book.userId, generation: 7,
            contentRevision: fixture.fingerprint.version.materializationRevision, tombstoned: true
        )
        #expect(await fixture.persistence.parkSampleRepair(book: fixture.book, token: job.token) == .supersededOrFenced)
        await expectUnauthorizedPendingRead(fixture.persistence, book: fixture.book)
        let after = try #require(await fixture.persistence.pendingMaterializationForDeletionCleanup(
            bookID: fixture.book.id, ownerID: fixture.book.userId
        ))
        #expect(after.token == job.token)
        #expect(after.phase == .paused)
        #expect(try await SwiftDataBookStore(dbStore: fixture.db).book(fixture.book.id) == fixture.book)
    }

    @Test("sample repair parking refuses changed Book or fingerprint authority without mutating the job")
    func sampleRepairParkingRejectsChangedCanonicalAndFingerprint() async throws {
        let canonicalFixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: canonicalFixture.root) }
        try FileManager.default.removeItem(at: canonicalFixture.managedURL)
        let canonicalJob = makeSampleRepairJob(book: canonicalFixture.book, sha256: canonicalFixture.fingerprint.sha256)
        guard case .reserved = try await canonicalFixture.persistence.reserveSampleRepair(
            sampleRepairRequest(canonicalFixture, job: canonicalJob, expectedPriorPendingToken: nil)
        ) else {
            Issue.record("missing sample did not reserve")
            return
        }
        var changedBook = canonicalFixture.book
        changedBook.title += " changed"
        try await SwiftDataBookStore(dbStore: canonicalFixture.db).upsert(changedBook)
        #expect(await canonicalFixture.persistence.parkSampleRepair(book: canonicalFixture.book, token: canonicalJob.token) == .supersededOrFenced)
        let canonicalPending = try #require(await canonicalFixture.persistence.pendingMaterializationForDeletionCleanup(
            bookID: canonicalFixture.book.id, ownerID: canonicalFixture.book.userId
        ))
        #expect(canonicalPending.token == canonicalJob.token)
        #expect(canonicalPending.phase == .registered)
        #expect(try await SwiftDataBookStore(dbStore: canonicalFixture.db).book(canonicalFixture.book.id) == changedBook)

        let fingerprintFixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fingerprintFixture.root) }
        try FileManager.default.removeItem(at: fingerprintFixture.managedURL)
        let fingerprintJob = makeSampleRepairJob(book: fingerprintFixture.book, sha256: fingerprintFixture.fingerprint.sha256)
        guard case .reserved = try await fingerprintFixture.persistence.reserveSampleRepair(
            sampleRepairRequest(fingerprintFixture, job: fingerprintJob, expectedPriorPendingToken: nil)
        ) else {
            Issue.record("missing sample did not reserve")
            return
        }
        try await fingerprintFixture.db.write { context in
            guard let stored = try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).first else {
                throw TestFailure.expected
            }
            stored.sha256 = String(repeating: "0", count: 64)
        }
        #expect(await fingerprintFixture.persistence.parkSampleRepair(book: fingerprintFixture.book, token: fingerprintJob.token) == .supersededOrFenced)
        let fingerprintPending = try #require(await fingerprintFixture.persistence.pendingMaterializationForDeletionCleanup(
            bookID: fingerprintFixture.book.id, ownerID: fingerprintFixture.book.userId
        ))
        #expect(fingerprintPending.token == fingerprintJob.token)
        #expect(fingerprintPending.phase == .registered)
        #expect(try await SwiftDataBookStore(dbStore: fingerprintFixture.db).book(fingerprintFixture.book.id) == fingerprintFixture.book)

        let revokedFixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: revokedFixture.root) }
        try FileManager.default.removeItem(at: revokedFixture.managedURL)
        let revokedJob = makeSampleRepairJob(book: revokedFixture.book, sha256: revokedFixture.fingerprint.sha256)
        guard case .reserved = try await revokedFixture.persistence.reserveSampleRepair(
            sampleRepairRequest(revokedFixture, job: revokedJob, expectedPriorPendingToken: nil)
        ) else {
            Issue.record("missing sample did not reserve")
            return
        }
        try await revokedFixture.persistence.setAccountAuthorization(ownerID: revokedFixture.book.userId, generation: nil)
        #expect(await revokedFixture.persistence.parkSampleRepair(book: revokedFixture.book, token: revokedJob.token) == .supersededOrFenced)
        await expectUnauthorizedPendingRead(revokedFixture.persistence, book: revokedFixture.book)
        let revokedPending = try #require(await revokedFixture.persistence.pendingMaterializationForDeletionCleanup(
            bookID: revokedFixture.book.id, ownerID: revokedFixture.book.userId
        ))
        #expect(revokedPending.token == revokedJob.token)
        #expect(revokedPending.phase == .registered)
        #expect(try await SwiftDataBookStore(dbStore: revokedFixture.db).book(revokedFixture.book.id) == revokedFixture.book)
    }

    @Test("present matching bytes cannot hide an active sample repair attempt")
    func sampleRepairRejectsPresentBytesWhileAttemptIsActive() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let displacedURL = fixture.root.appendingPathComponent("displaced-sample.epub")
        try FileManager.default.moveItem(at: fixture.managedURL, to: displacedURL)
        let active = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: active)) else {
            Issue.record("missing bytes did not reserve the first attempt")
            return
        }
        #expect(try await fixture.persistence.transition(token: active.token, from: .registered, to: .copying))
        try FileManager.default.moveItem(at: displacedURL, to: fixture.managedURL)
        let restoredVersion = try FileManagedFileVersionInspector().managedFileVersion(
            at: fixture.managedURL, materializationRevision: fixture.fingerprint.version.materializationRevision
        )
        #expect(restoredVersion == fixture.fingerprint.version)

        let competing = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(
                fixture, job: competing, expectedManagedFileVersion: fixture.fingerprint.version,
                expectedPriorPendingToken: active.token
            ))
        }
        let retained = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(retained.token == active.token)
        #expect(retained.phase == .copying)
        #expect(try await SwiftDataBookStore(dbStore: fixture.db).books(for: fixture.book.userId).count == 1)
    }

    @Test("present exact bytes reconcile a paused sample repair to a readable managed source")
    func sampleRepairReconcilesPausedAttemptWithPresentBytes() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let displacedURL = fixture.root.appendingPathComponent("displaced-sample.epub")
        try FileManager.default.moveItem(at: fixture.managedURL, to: displacedURL)
        let paused = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: paused)) else {
            Issue.record("missing bytes did not reserve the first attempt")
            return
        }
        #expect(try await fixture.persistence.transition(token: paused.token, from: .registered, to: .copying))
        #expect(try await fixture.persistence.transition(token: paused.token, from: .copying, to: .paused))
        try FileManager.default.moveItem(at: displacedURL, to: fixture.managedURL)
        let restoredVersion = try FileManagedFileVersionInspector().managedFileVersion(
            at: fixture.managedURL, materializationRevision: fixture.fingerprint.version.materializationRevision
        )
        #expect(restoredVersion == fixture.fingerprint.version)

        let retry = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        let result = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(
            fixture, job: retry, expectedManagedFileVersion: fixture.fingerprint.version,
            expectedPriorPendingToken: paused.token
        ))
        guard case let .reconciled(fingerprint) = result else {
            Issue.record("paused attempt with verified present bytes did not reconcile")
            return
        }
        #expect(fingerprint == fixture.fingerprint)
        let ready = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(ready.phase == .ready)
        #expect(ready.sourceKind == .sampleRepair)
        #expect(ready.token == paused.token)
        #expect(try await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId) == fixture.fingerprint)

        let ownerID = fixture.book.userId
        let root = fixture.root
        let registry = BookSourceRegistry(
            persistence: fixture.persistence, currentGeneration: { 7 }, currentOwnerID: { ownerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lease = try await registry.acquireReadableSource(for: fixture.book)
        #expect(lease.url.standardizedFileURL == fixture.managedURL.standardizedFileURL)
        #expect(lease.cachePolicy == .managed(bookID: fixture.book.id, version: fixture.fingerprint.version))
    }

    @Test("restored file metadata cannot pass a sample repair as already managed when bytes changed")
    func sampleRepairRejectsCorruptBytesWithMatchingFileVersion() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handle = try FileHandle(forWritingTo: fixture.managedURL)
        try handle.write(contentsOf: Data(repeating: 0x5a, count: Int(fixture.fingerprint.version.byteCount)))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.fingerprint.version.modificationDate],
            ofItemAtPath: fixture.managedURL.path
        )
        let spoofedVersion = try FileManagedFileVersionInspector().managedFileVersion(
            at: fixture.managedURL,
            materializationRevision: fixture.fingerprint.version.materializationRevision
        )
        #expect(spoofedVersion == fixture.fingerprint.version, "fixture must preserve inode, size and mtime")

        let job = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(
                fixture, job: job, expectedManagedFileVersion: fixture.fingerprint.version
            ))
        }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)
        #expect(try await SwiftDataBookStore(dbStore: fixture.db).book(fixture.book.id) == fixture.book)
    }

    @Test("only explicitly marked sample repair jobs may reserve an existing Book ID")
    func sampleRepairRejectsOrdinarySourceKind() async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.managedURL)
        let repair = makeSampleRepairJob(book: fixture.book, sha256: fixture.fingerprint.sha256)
        let ordinary = PendingBookMaterialization(
            token: repair.token, sourceKind: .securityScopedOriginal,
            sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: repair.sourceVersion,
            expectedSHA256: repair.expectedSHA256, expectedByteCount: repair.expectedByteCount,
            stagingRelativePath: repair.stagingRelativePath,
            destinationRelativePath: repair.destinationRelativePath, phase: .registered
        )

        await #expect(throws: Error.self) {
            _ = try await fixture.persistence.reserveSampleRepair(sampleRepairRequest(fixture, job: ordinary))
        }
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)
        #expect(try await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId) == fixture.fingerprint)
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
        let accountPermit = AccountMutationPermit(ownerID: book.userId, accountGeneration: activeGeneration)
        let expectation = try #require(await persistence.retryExpectation(bookID: book.id, ownerID: book.userId, accountPermit: accountPermit))
        let retired = RetiredBookMaterializationAttempt(token: recovered)
        let legacyPath = try #require(await persistence.joinOrRetryPending(
            ownerID: book.userId, sha256: oldJob.expectedSHA256, newSource: retry, retiredAttempt: retired
        ))
        #expect(legacyPath.disposition == .retryRequired)
        let retried = try #require(await persistence.retryPendingMaterialization(
            expected: expectation, accountPermit: accountPermit, newSource: retry,
            verifiedSourceSHA256: oldJob.expectedSHA256, verifiedSourceByteCount: oldJob.expectedByteCount,
            verifiedSourceVersion: retry.sourceVersion, retiredAttempt: retired
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

    private func makeJob(book: Book, attemptID: UUID = UUID(), sha256: String = "aabb", expectedByteCount: Int64 = 42, generation: UInt64 = 7, destinationFileIdentifier: String? = nil, promotionRevision: UUID? = nil) -> PendingBookMaterialization {
        PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: generation, bookID: book.id, attemptID: attemptID),
            sourceKind: .ownedStaging,
            sourceBookmark: nil,
            ownedSourceRelativePath: "staging/source.epub",
            sourceVersion: ManagedFileVersion(byteCount: expectedByteCount, modificationDate: Date(timeIntervalSince1970: 100), fileIdentifier: "source", materializationRevision: UUID()),
            expectedSHA256: sha256,
            expectedByteCount: expectedByteCount,
            stagingRelativePath: "staging/import.part",
            destinationRelativePath: book.fileURL,
            phase: .registered,
            destinationFileIdentifier: destinationFileIdentifier,
            promotionRevision: promotionRevision
        )
    }

    private func makeSampleRepairJob(book: Book, sha256: String, expectedByteCount: Int64 = 42, generation: UInt64 = 7) -> PendingBookMaterialization {
        let attempt = UUID()
        return PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: book.userId, accountGeneration: generation, bookID: book.id, attemptID: attempt),
            sourceKind: .sampleRepair,
            sourceBookmark: nil,
            ownedSourceRelativePath: nil,
            sourceVersion: ManagedFileVersion(byteCount: expectedByteCount, modificationDate: Date(timeIntervalSince1970: 100), fileIdentifier: "sample-source", materializationRevision: UUID()),
            expectedSHA256: sha256,
            expectedByteCount: expectedByteCount,
            stagingRelativePath: "Imports/\(attempt.uuidString)/content.partial",
            destinationRelativePath: book.fileURL,
            phase: .registered
        )
    }

    private func sampleRepairRequest(
        _ fixture: ReadySampleFixture,
        job: PendingBookMaterialization,
        expectedManagedFileVersion: ManagedFileVersion? = nil,
        expectedPriorPendingToken: BookMaterializationToken? = nil
    ) -> SampleRepairReservationRequest {
        SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fixture.fingerprint,
            canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: expectedManagedFileVersion,
            expectedPriorPendingToken: expectedPriorPendingToken, job: job
        )
    }

    private func expectUnauthorizedPendingRead(
        _ persistence: SwiftDataBookImportPersistence,
        book: Book
    ) async {
        do {
            _ = try await persistence.pendingMaterialization(bookID: book.id, ownerID: book.userId)
            Issue.record("normal pending reader should reject revoked or tombstoned authority")
        } catch SwiftDataBookImportPersistence.PersistenceError.unauthorized {
            // Cleanup-only reads below intentionally remain available.
        } catch {
            Issue.record("expected unauthorized pending read, got \(error)")
        }
    }

    @Test("generation-aware digest cache rejects stale generation, path, version and reading authority", arguments: ["generation", "path", "version", "permit"])
    func digestCacheRequiresCurrentAuthority(_ staleInput: String) async throws {
        let fixture = try await makeReadySample()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fingerprint = fixture.fingerprint
        if staleInput == "version" {
            try FileManager.default.setAttributes(
                [.modificationDate: fingerprint.version.modificationDate.addingTimeInterval(10)],
                ofItemAtPath: fixture.managedURL.path
            )
        }
        if staleInput == "permit" {
            try await fixture.persistence.setBookReadingAuthorization(
                bookID: fixture.book.id, ownerID: fixture.book.userId, generation: 7,
                contentRevision: fingerprint.version.materializationRevision, tombstoned: true
            )
        }
        let expectedGeneration: UInt64 = staleInput == "generation" ? 8 : 7
        let expectedPath = staleInput == "path" ? fixture.book.fileURL + ".stale" : fixture.book.fileURL
        #expect(try await fixture.persistence.cacheManagedFingerprint(
            fingerprint, expectedGeneration: expectedGeneration,
            expectedRelativePath: expectedPath, expectedVersion: fingerprint.version
        ) == false)
        let unchanged = try await fixture.db.read { context in
            try context.fetch(FetchDescriptor<BookFileFingerprintEntity>()).first?.value
        }
        #expect(unchanged == fingerprint)
        let permit = try await fixture.persistence.readingPermit(
            bookID: fixture.book.id, ownerID: fixture.book.userId, generation: 7
        )
        #expect((permit == nil) == (staleInput == "permit"))
    }

    private func makeReadySample() async throws -> ReadySampleFixture {
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sample-repair-\(UUID().uuidString)", isDirectory: true)
        let book = Book(userId: UUID(), title: "Sample", author: "Original author", formatType: .epub, openedAt: Date(timeIntervalSince1970: 123), fileURL: "books/sample.epub")
        let managedURL = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x4a, count: 42)
        try bytes.write(to: managedURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 12_345)], ofItemAtPath: managedURL.path)
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: book.userId, sha256: digest, version: version)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await SwiftDataBookStore(dbStore: db).upsert(book)
        try await persistence.setAccountAuthorization(ownerID: book.userId, generation: 7)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: book.userId, generation: 7, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: 7, expectedRelativePath: book.fileURL, expectedVersion: version))
        let acceptance = BookServerAcceptance(sha256: digest, acceptedOperationID: UUID(), acceptedAt: Date(timeIntervalSince1970: 456))
        let permit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: book.userId, generation: 7))
        #expect(try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: fingerprint, acceptance: acceptance))
        let acceptedFingerprint = try #require(await persistence.fingerprint(bookID: book.id, ownerID: book.userId))
        #expect(acceptedFingerprint.serverAcceptance == acceptance)
        return ReadySampleFixture(db: db, root: root, book: book, managedURL: managedURL, fingerprint: acceptedFingerprint, acceptance: acceptance, persistence: persistence)
    }

    private struct ReadySampleFixture {
        let db: RishiDBStore
        let root: URL
        let book: Book
        let managedURL: URL
        let fingerprint: BookFileFingerprint
        let acceptance: BookServerAcceptance
        let persistence: SwiftDataBookImportPersistence
    }

    private enum TestFailure: Error { case expected }
}
