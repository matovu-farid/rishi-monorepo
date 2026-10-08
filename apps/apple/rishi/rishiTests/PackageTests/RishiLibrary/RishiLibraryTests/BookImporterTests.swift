@testable import rishi
import CryptoKit
import Foundation
import Testing

/// Plan 34-17 — `BookImporter` owns the import orchestration extracted from
/// `BookFileStorage`. The pipeline is exhaustively covered through the
/// `BookFileStorage.importBook` facade (`BookFileStorageTests`,
/// `BookIndexingHookTests`); this suite locks in the new direct seam: driving
/// `BookImporter` on its own produces identical on-disk results, ids, and
/// upserts.
@Suite(.serialized)
struct BookImporterTests {

    @Test("content matching skips a retired identical candidate and reuses a live source")
    func retiredIdenticalCandidateDoesNotHideLiveEdition() async throws {
        let root = makeTempRoot("retired-fingerprint-candidates")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID()
        let retired = Book(userId: owner, title: "Retired", formatType: .epub, addedAt: Date(), fileURL: "retired.epub")
        let live = Book(userId: owner, title: "Live", formatType: .epub, addedAt: Date().addingTimeInterval(-1), fileURL: "live.epub")
        let source = root.appendingPathComponent(retired.fileURL)
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: false)
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(live.fileURL))
        let store = InMemoryBookStore()
        try await store.upsert(retired); try await store.upsert(live)
        let service = BookFingerprintService(rootURL: root, bookStore: store, currentGeneration: { 1 },
            isRetired: { book, _ in book.id == retired.id }, isSourceAvailable: { $0.id == live.id })
        let selected = try await service.probeSelectedSource(at: source, metadataExtractor: nil)
        #expect(try await service.matchingBook(ownerID: owner, byteCount: selected.byteCount, sha256: selected.sha256)?.id == live.id)
        try await store.delete(live.id)
        do {
            _ = try await service.matchingBook(ownerID: owner, byteCount: selected.byteCount, sha256: selected.sha256)
            Issue.record("A retired matching source did not report deletion in progress")
        } catch let error as BookImportFailure { #expect(error == .deletionInProgress) }
    }

    @Test("managed relative paths canonicalize aliases and reject escapes")
    func managedRelativePathIsCanonicalAndStrict() throws {
        let parent = URL.temporaryDirectory.appendingPathComponent("ManagedPath-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: parent) }

        let missingLeaf = root.appendingPathComponent("Books/absent/book.epub")
        #expect(try ManagedRelativePath.make(root: alias, target: missingLeaf) == "Books/absent/book.epub")
        #expect(throws: Error.self) {
            try ManagedRelativePath.make(root: root, target: parent.appendingPathComponent("root-sibling/file.epub"))
        }
        #expect(throws: Error.self) {
            try ManagedRelativePath.make(root: root, target: root.appendingPathComponent("../outside.epub"))
        }

        let escaped = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: parent)
        #expect(throws: Error.self) {
            try ManagedRelativePath.make(root: root, target: escaped.appendingPathComponent("outside.epub"))
        }
    }

    @Test("import rejects an escaped Books directory before writing or persisting")
    func importRejectsBooksSymlinkEscape() async throws {
        let root = makeTempRoot("escaped-books-root")
        let outside = makeTempRoot("escaped-books-outside")
        let sourceDirectory = makeTempRoot("escaped-books-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Books", isDirectory: true),
            withDestinationURL: outside
        )
        let source = sourceDirectory.appendingPathComponent("escaped.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: false)
        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let owner = UUID()

        await #expect(throws: Error.self) {
            _ = try await importer.importBook(from: source, ownerId: owner)
        }
        #expect(try await store.books(for: owner).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("absolute persisted Book paths are never considered readable")
    func absolutePersistedPathIsRejectedByAvailability() async throws {
        let root = makeTempRoot("absolute-book-path")
        let outside = makeTempRoot("absolute-book-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = outside.appendingPathComponent("external.epub")
        try Data("external".utf8).write(to: file)
        let owner = UUID()
        let book = Book(userId: owner, title: "External", author: nil, formatType: .epub, fileURL: file.path)
        let store = InMemoryBookStore()
        try await store.upsert(book)
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])

        #expect(!(await storage.isReadableSourceAvailable(for: book, ownerID: owner, accountGeneration: 1)))
    }

    @Test("both availability APIs reject a Book below an escaped Books directory")
    func availabilityRejectsBooksSymlinkEscape() async throws {
        let root = makeTempRoot("availability-books-root")
        let outside = makeTempRoot("availability-books-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("book.epub"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Books", isDirectory: true),
            withDestinationURL: outside
        )
        let owner = UUID()
        let book = Book(userId: owner, title: "Escaped", formatType: .epub, fileURL: "Books/book.epub")
        let store = InMemoryBookStore()
        try await store.upsert(book)
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let registration = SourceReadableBookRegistration(book: book, state: .managed)

        #expect(!(await storage.isReadableSourceAvailable(for: book, ownerID: owner, accountGeneration: 1)))
        #expect(!(await storage.validateSourceReadableRegistration(registration, ownerId: owner, accountGeneration: 1)))
    }

    @Test("owned-source registration rejects an escaped Imports directory before reservation")
    func ownedSourceRejectsImportsSymlinkEscape() async throws {
        let root = makeTempRoot("escaped-imports-root")
        let outside = makeTempRoot("escaped-imports-outside")
        let sourceDirectory = makeTempRoot("escaped-imports-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Imports", isDirectory: true),
            withDestinationURL: outside
        )
        let source = sourceDirectory.appendingPathComponent("owned.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: false)
        let owner = UUID()
        let generation: UInt64 = 5
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await persistence.setAccountAuthorization(ownerID: owner, generation: generation)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { owner },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry,
            persistence: persistence, bookStore: books, currentGeneration: { generation }
        )
        let storage = BookFileStorage(
            rootURL: root, bookStore: books, coverExtractors: [:],
            fingerprintPersistence: persistence,
            fingerprintAccountGeneration: { generation },
            materializationCoordinator: coordinator
        )

        await #expect(throws: Error.self) {
            _ = try await storage.registerOwnedSourceReadable(
                from: source, ownerId: owner, accountGeneration: generation
            )
        }
        #expect(try await books.books(for: owner).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("owned retry validates its new Imports path after the root changes")
    func ownedRetryRejectsImportsSymlinkSwap() async throws {
        let root = makeTempRoot("retry-imports-root")
        let outside = makeTempRoot("retry-imports-outside")
        let sourceDirectory = makeTempRoot("retry-imports-source")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let source = sourceDirectory.appendingPathComponent("retry.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: false)
        let owner = UUID()
        let generation: UInt64 = 5
        let store = InMemoryBookStore()
        let persistence = ImportsSwapRetryPersistence(root: root, outside: outside)
        let registry = BookSourceRegistry(
            persistence: persistence,
            currentGeneration: { generation },
            currentOwnerID: { owner },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: lifecycle, sourceRegistry: registry,
            persistence: persistence, bookStore: store, currentGeneration: { generation }
        )
        let storage = BookFileStorage(
            rootURL: root, bookStore: store, coverExtractors: [:],
            fingerprintPersistence: persistence,
            fingerprintAccountGeneration: { generation },
            materializationCoordinator: coordinator
        )

        await #expect(throws: Error.self) {
            _ = try await storage.registerOwnedSourceReadable(
                from: source, ownerId: owner, accountGeneration: generation
            )
        }
        #expect(await persistence.reservationCount == 2)
        #expect(try await store.books(for: owner).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["staged-imports"])
        let stagedRoot = outside.appendingPathComponent("staged-imports", isDirectory: true)
        let stagedAttempts = try FileManager.default.contentsOfDirectory(atPath: stagedRoot.path)
        #expect(stagedAttempts.count == 2)
        for attempt in stagedAttempts {
            let stagedSource = stagedRoot.appendingPathComponent(attempt, isDirectory: true)
                .appendingPathComponent("source.epub")
            #expect(FileManager.default.fileExists(atPath: stagedSource.path))
        }
    }

    private func makeTempRoot(_ label: String) -> URL {
        let dir = URL.temporaryDirectory
            .appendingPathComponent("BookImporterTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImporter(
        rootURL: URL,
        bookStore: any BookStore,
        bookIndexingHook: any BookIndexingHook = NoopBookIndexingHook(),
        metadataExtractors: [String: any MetadataExtractor]? = nil,
        isTombstoned: (@Sendable (BookID) async -> Bool)? = nil
    ) -> BookImporter {
        BookImporter(
            rootURL: rootURL,
            booksDirURL: rootURL.appendingPathComponent("Books", isDirectory: true),
            bookStore: bookStore,
            coverExtractors: [
                "pdf": PDFKitCoverExtractor(targetSize: CGSize(width: 120, height: 160)),
                "epub": EpubCoverExtractor()
            ],
            metadataExtractors: metadataExtractors ?? [
                "pdf": PDFKitMetadataExtractor(),
                "epub": EpubMetadataExtractor()
            ],
            bookIndexingHook: bookIndexingHook,
            isTombstoned: isTombstoned
        )
    }

    @Test("importBook copies the file under Books/<id>/, writes a relative fileURL, and upserts")
    func importPDF_copiesFileAndPersistsBook() async throws {
        let root = makeTempRoot("import-pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-pdf-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcPDF = srcDir.appendingPathComponent("alice.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcPDF)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let userId = UUID()

        let book = try await importer.importBook(from: srcPDF, ownerId: userId)

        // Relative fileURL under Books/<id>/
        #expect(book.fileURL == "Books/\(book.id.uuidString)/alice.pdf")
        // File physically copied
        let abs = root.appendingPathComponent(book.fileURL)
        #expect(FileManager.default.fileExists(atPath: abs.path))
        // Row persisted
        let stored = try await store.book(book.id)
        #expect(stored?.id == book.id)
        #expect(stored?.userId == userId)
    }

    @Test("importBook throws unsupportedFormat for an unknown extension")
    func importUnsupported_throws() async throws {
        let root = makeTempRoot("import-unsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-unsupported-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let bogus = srcDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: bogus)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)

        await #expect(throws: BookFileStorage.StorageError.self) {
            _ = try await importer.importBook(from: bogus, ownerId: UUID())
        }
    }

    @Test("importBook keeps different content separate even when metadata matches")
    func differentContent_sameMetadata_getsSeparateIdentity() async throws {
        let root = makeTempRoot("import-dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-dedup-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        // Same embedded metadata, different content -> separate identities.
        let srcA = srcDir.appendingPathComponent("alpha.epub")
        let srcB = srcDir.appendingPathComponent("beta.epub")
        try await FixtureBuilders.writeTinyEPUB(to: srcA, withCover: true)
        try await FixtureBuilders.writeTinyEPUB(to: srcB, withCover: false)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let userId = UUID()

        let bookA = try await importer.importBook(from: srcA, ownerId: userId)
        let bookB = try await importer.importBook(from: srcB, ownerId: userId)

        #expect(bookA.id != bookB.id, "Different content must not overwrite an existing book")
        #expect((await store.snapshot()).count == 2)
    }

    @Test("importBook deduplicates identical content even when metadata differs")
    func contentHash_deduplicatesDifferentMetadata() async throws {
        let root = makeTempRoot("import-content-hash")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-content-hash-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcA = srcDir.appendingPathComponent("first-copy.pdf")
        let srcB = srcDir.appendingPathComponent("second-copy.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcA)
        try FileManager.default.copyItem(at: srcA, to: srcB)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store, metadataExtractors: [:])
        let userId = UUID()

        let bookA = try await importer.importBook(from: srcA, ownerId: userId)
        let bookB = try await importer.importBook(from: srcB, ownerId: userId)

        #expect(bookB.id == bookA.id)
        #expect((await store.snapshot()).count == 1)
    }

    @Test("importBook preserves another user's deterministic book identity")
    func deterministicIdentityCollisionAcrossUsersRotatesIdentity() async throws {
        let root = makeTempRoot("import-cross-user-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-cross-user-collision-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let source = srcDir.appendingPathComponent("shared.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: true)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store)
        let firstUser = UUID()
        let secondUser = UUID()
        let firstBook = try await importer.importBook(from: source, ownerId: firstUser)
        let secondBook = try await importer.importBook(from: source, ownerId: secondUser)

        #expect(secondBook.id != firstBook.id)
        #expect(try await store.book(firstBook.id)?.userId == firstUser)
        #expect(try await store.book(secondBook.id)?.userId == secondUser)
        #expect((await store.snapshot()).count == 2)
    }

    @Test("importBook deduplicates concurrent copies of the same content")
    func concurrentImports_sameContent_createOneBook() async throws {
        let root = makeTempRoot("import-concurrent-dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-concurrent-dedup-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcA = srcDir.appendingPathComponent("copy-a.pdf")
        let srcB = srcDir.appendingPathComponent("copy-b.pdf")
        try FixtureBuilders.writeTinyPDF(to: srcA)
        try FileManager.default.copyItem(at: srcA, to: srcB)

        let store = InMemoryBookStore()
        let importer = makeImporter(rootURL: root, bookStore: store, metadataExtractors: [:])
        let userId = UUID()
        let imported = try await withThrowingTaskGroup(of: Book.self, returning: [Book].self) { group in
            group.addTask { try await importer.importBook(from: srcA, ownerId: userId) }
            group.addTask { try await importer.importBook(from: srcB, ownerId: userId) }
            var books: [Book] = []
            for try await book in group {
                books.append(book)
            }
            return books
        }

        #expect(imported.count == 2)
        #expect(Set(imported.map(\.id)).count == 1)
        #expect((await store.snapshot()).count == 1)
    }

    @Test("importBook rotates identity when the deterministic candidate is tombstoned")
    func tombstonedDeterministicIdReceivesFreshIdentity() async throws {
        let root = makeTempRoot("import-tombstone")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = makeTempRoot("import-tombstone-src")
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let source = srcDir.appendingPathComponent("thinking-in-bets.epub")
        try await FixtureBuilders.writeTinyEPUB(to: source, withCover: true)

        let store = InMemoryBookStore()
        let original = try await makeImporter(rootURL: root, bookStore: store)
            .importBook(from: source, ownerId: UUID())
        let reimported = try await makeImporter(
            rootURL: root,
            bookStore: store,
            isTombstoned: { candidate in candidate == original.id }
        ).importBook(from: source, ownerId: original.userId)

        #expect(reimported.id != original.id)
        #expect(try await store.book(reimported.id)?.id == reimported.id)
    }

    @Test("sample repair restores exact missing bytes at the existing Book ID")
    func missingSampleRepairPreservesBookAndAnnotations() async throws {
        let fixture = try await makeMissingSampleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let position = Position(bookId: fixture.book.id, locator: "epubcfi(/6/8)", percentComplete: 0.6)
        let bookmark = Bookmark(bookId: fixture.book.id, locator: "epubcfi(/6/4)")
        try await SwiftDataPositionStore(dbStore: fixture.db).upsert(position)
        try await SwiftDataBookmarkStore(dbStore: fixture.db).upsert(bookmark)

        let result = try await fixture.storage.repairMissingSample(
            for: fixture.book, from: fixture.sourceURL,
            ownerID: fixture.book.userId, accountGeneration: fixture.generation
        )
        guard case let .repaired(repairedBook) = result else {
            Issue.record("missing sample was not repaired")
            return
        }
        #expect(repairedBook.id == fixture.book.id)
        #expect(repairedBook == fixture.book)
        #expect(try Data(contentsOf: fixture.managedURL) == fixture.bytes)
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        #expect(try await fixture.books.books(for: fixture.book.userId).count == 1)
        #expect(try await SwiftDataPositionStore(dbStore: fixture.db).position(for: fixture.book.id) == position)
        #expect(try await SwiftDataBookmarkStore(dbStore: fixture.db).bookmark(bookmark.id) == bookmark)
        #expect(try await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId)?.serverAcceptance == fixture.acceptance)
    }

    @Test("sample repair failure leaves the same Book available for a later exact retry")
    func failedSampleRepairCanRetryWithoutIdentityRotation() async throws {
        let fixture = try await makeMissingSampleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrongSource = fixture.root.appendingPathComponent("source/corrupt.epub")
        try Data(repeating: 0x7f, count: fixture.bytes.count).write(to: wrongSource)
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: wrongSource, revision: UUID()))
        let attempt = BookMaterializationToken(ownerID: fixture.book.userId, accountGeneration: fixture.generation, bookID: fixture.book.id, attemptID: UUID())
        let expectedFingerprint = try #require(await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId))
        let job = PendingBookMaterialization(
            token: attempt, sourceKind: .sampleRepair, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: sourceVersion,
            expectedSHA256: expectedFingerprint.sha256, expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(attempt.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: expectedFingerprint,
            canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
        )) else {
            Issue.record("missing sample did not reserve a materialization attempt")
            return
        }
        await #expect(throws: Error.self) {
            _ = try await fixture.coordinator.materialize(book: fixture.book, token: attempt, sourceURL: wrongSource, repairOnly: true)
        }
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))
        #expect(try await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId)?.phase == .paused)
        #expect(try await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId) == nil)
        #expect(try await fixture.persistence.sampleRepairFingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId) == expectedFingerprint)

        let result = try await fixture.storage.repairMissingSample(
            for: fixture.book, from: fixture.sourceURL,
            ownerID: fixture.book.userId, accountGeneration: fixture.generation
        )
        guard case let .repaired(book) = result else {
            Issue.record("retry did not repair the same Book")
            return
        }
        #expect(book.id == fixture.book.id)
        #expect(try await fixture.books.books(for: fixture.book.userId).count == 1)
        #expect(try Data(contentsOf: fixture.managedURL) == fixture.bytes)
        let ready = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(ready.phase == .ready)
        #expect(ready.token.attemptID != attempt.attemptID)
    }

    @Test("early source registration failure pauses sample repair and permits exact retry")
    func earlySampleRepairSourceFailureRemainsRetryable() async throws {
        let fixture = try await makeMissingSampleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fingerprint = try #require(await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId))
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: fixture.sourceURL, revision: UUID()))
        let token = BookMaterializationToken(ownerID: fixture.book.userId, accountGeneration: fixture.generation, bookID: fixture.book.id, attemptID: UUID())
        let job = PendingBookMaterialization(
            token: token, sourceKind: .sampleRepair, sourceBookmark: nil, ownedSourceRelativePath: nil,
            sourceVersion: sourceVersion, expectedSHA256: fingerprint.sha256, expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fingerprint,
            canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
        )) else {
            Issue.record("missing sample did not reserve the repair attempt")
            return
        }

        let generation = fixture.generation
        let root = fixture.root
        let wrongOwnerID = UUID()
        let rejectingRegistry = BookSourceRegistry(
            persistence: fixture.persistence, currentGeneration: { generation }, currentOwnerID: { wrongOwnerID },
            managedURL: { root.appendingPathComponent($0.fileURL) }
        )
        let rejectingLifecycle = BookImportLifecycle(sourceRegistry: rejectingRegistry, currentAccountGeneration: { generation })
        let rejectingCoordinator = BookMaterializationCoordinator(
            rootURL: root, lifecycle: rejectingLifecycle, sourceRegistry: rejectingRegistry,
            persistence: fixture.persistence, bookStore: fixture.books, currentGeneration: { generation }
        )
        await #expect(throws: BookSourceRegistryError.accountRevoked) {
            _ = try await rejectingCoordinator.materialize(book: fixture.book, token: token, sourceURL: fixture.sourceURL, repairOnly: true)
        }
        let paused = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(paused.token == token)
        #expect(paused.phase == .paused)
        #expect(paused.sourceKind == .sampleRepair)
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))

        let result = try await fixture.storage.repairMissingSample(
            for: fixture.book, from: fixture.sourceURL, ownerID: fixture.book.userId, accountGeneration: generation
        )
        guard case let .repaired(book) = result else {
            Issue.record("exact retry did not repair the paused Book")
            return
        }
        #expect(book.id == fixture.book.id)
        #expect(try Data(contentsOf: fixture.managedURL) == fixture.bytes)
        #expect(try await fixture.books.books(for: fixture.book.userId).count == 1)
        let ready = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(ready.phase == .ready)
        #expect(ready.token.attemptID != token.attemptID)
    }

    @Test("paused sample repair reconciliation publishes readiness after a terminal source failure")
    func pausedSampleRepairReconciliationClearsSourceFailure() async throws {
        let fixture = try await makeMissingSampleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fingerprint = try #require(await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId))
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: fixture.sourceURL, revision: UUID()))
        let token = BookMaterializationToken(
            ownerID: fixture.book.userId, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        let job = PendingBookMaterialization(
            token: token, sourceKind: .sampleRepair, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: sourceVersion,
            expectedSHA256: fingerprint.sha256, expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(token.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fingerprint,
            canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: job
        )) else {
            Issue.record("missing sample did not reserve the repair attempt")
            return
        }
        #expect(try await fixture.persistence.transition(token: token, from: .registered, to: .copying))
        #expect(try await fixture.persistence.transition(token: token, from: .copying, to: .paused))
        try FileManager.default.moveItem(at: fixture.displacedManagedURL, to: fixture.managedURL)
        let restoredVersion = try FileManagedFileVersionInspector().managedFileVersion(
            at: fixture.managedURL, materializationRevision: fingerprint.version.materializationRevision
        )
        #expect(restoredVersion == fingerprint.version)
        await fixture.registry.failPendingSource(
            ownerID: fixture.book.userId, generation: fixture.generation,
            bookID: fixture.book.id, error: BookSourceRegistryError.unavailable
        )
        await #expect(throws: BookSourceRegistryError.unavailable) {
            _ = try await fixture.coordinator.awaitManagedSource(for: fixture.book)
        }

        let result = try await fixture.storage.repairMissingSample(
            for: fixture.book, from: fixture.sourceURL,
            ownerID: fixture.book.userId, accountGeneration: fixture.generation
        )
        guard case let .alreadyManaged(book) = result else {
            Issue.record("exact present bytes did not reconcile the paused repair")
            return
        }
        #expect(book.id == fixture.book.id)
        let ready = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(ready.phase == .ready)
        #expect(ready.token == token)
        let managed = try await fixture.coordinator.awaitManagedSource(for: fixture.book)
        #expect(managed.fingerprint == fingerprint)
        #expect(managed.url.standardizedFileURL == fixture.managedURL.standardizedFileURL)
        let lease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        #expect(lease.url.standardizedFileURL == fixture.managedURL.standardizedFileURL)
        #expect(lease.cachePolicy == .managed(bookID: fixture.book.id, version: fingerprint.version))
    }

    @Test("ordinary same-digest picker retry cannot take a paused sample repair attempt")
    func pickerCannotReplacePausedSampleRepairAndOverwriteManagedPath() async throws {
        let fixture = try await makeMissingSampleFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fingerprint = try #require(await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: fixture.book.userId))
        let sourceVersion = try #require(try CoordinatedSourceProbe.version(at: fixture.sourceURL, revision: UUID()))
        let repairToken = BookMaterializationToken(
            ownerID: fixture.book.userId, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        let repair = PendingBookMaterialization(
            token: repairToken, sourceKind: .sampleRepair, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: sourceVersion,
            expectedSHA256: fingerprint.sha256, expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(repairToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        guard case .reserved = try await fixture.persistence.reserveSampleRepair(SampleRepairReservationRequest(
            expectedBook: fixture.book, expectedFingerprint: fingerprint,
            canonicalManagedURL: fixture.managedURL, expectedManagedFileVersion: nil, expectedPriorPendingToken: nil, job: repair
        )) else {
            Issue.record("sample repair reservation did not start")
            return
        }
        #expect(try await fixture.persistence.transition(token: repairToken, from: .registered, to: .copying))
        #expect(try await fixture.persistence.transition(token: repairToken, from: .copying, to: .paused))
        let competingBytes = Data("another writer's managed bytes".utf8)
        try competingBytes.write(to: fixture.managedURL)

        let pickerBook = Book(userId: fixture.book.userId, title: "Picker copy", formatType: .epub, fileURL: "Books/picker-copy.epub")
        let pickerToken = BookMaterializationToken(
            ownerID: fixture.book.userId, accountGeneration: fixture.generation,
            bookID: pickerBook.id, attemptID: UUID()
        )
        let pickerJob = PendingBookMaterialization(
            token: pickerToken, sourceKind: .securityScopedOriginal, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: sourceVersion,
            expectedSHA256: fingerprint.sha256, expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(pickerToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: pickerBook.fileURL, phase: .registered
        )
        let collision = try await fixture.persistence.reserveRegistration(book: pickerBook, job: pickerJob, candidate: nil)
        #expect(collision.disposition == .retryRequired)
        #expect(collision.book.id == fixture.book.id)

        let retryToken = BookMaterializationToken(
            ownerID: fixture.book.userId, accountGeneration: fixture.generation,
            bookID: fixture.book.id, attemptID: UUID()
        )
        let ordinaryRetry = PendingBookMaterialization(
            token: retryToken, sourceKind: .securityScopedOriginal, sourceBookmark: nil,
            ownedSourceRelativePath: nil, sourceVersion: sourceVersion,
            expectedSHA256: fingerprint.sha256, expectedByteCount: Int64(fixture.bytes.count),
            stagingRelativePath: "Imports/\(retryToken.attemptID.uuidString)/content.partial",
            destinationRelativePath: fixture.book.fileURL, phase: .registered
        )
        let claimed = try? await fixture.persistence.joinOrRetryPending(
            ownerID: fixture.book.userId, sha256: fingerprint.sha256,
            newSource: ordinaryRetry, retiredAttempt: RetiredBookMaterializationAttempt(token: repairToken)
        )
        #expect(claimed?.disposition != .retried)
        let retained = try #require(await fixture.persistence.pendingMaterialization(bookID: fixture.book.id, ownerID: fixture.book.userId))
        #expect(retained.token == repairToken)
        #expect(retained.sourceKind == .sampleRepair)
        await #expect(throws: Error.self) {
            _ = try await fixture.coordinator.materialize(
                book: fixture.book, token: retryToken, sourceURL: fixture.sourceURL, repairOnly: false
            )
        }
        #expect(try Data(contentsOf: fixture.managedURL) == competingBytes)
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        #expect(try await fixture.books.books(for: fixture.book.userId).count == 1)
    }

    private func makeMissingSampleFixture() async throws -> MissingSampleFixture {
        let root = makeTempRoot("missing-sample")
        let sourceURL = root.appendingPathComponent("source/sample.epub")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FixtureBuilders.writeTinyEPUB(to: sourceURL, withCover: false)
        let bytes = try Data(contentsOf: sourceURL)
        let ownerID = UUID()
        let generation: UInt64 = 7
        let book = Book(userId: ownerID, title: "Annotated sample", author: "Original author", formatType: .epub,
                        openedAt: Date(timeIntervalSince1970: 123), fileURL: "Books/sample.epub")
        let managedURL = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: managedURL)
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: revision))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let fingerprint = BookFileFingerprint(bookID: book.id, ownerID: ownerID, sha256: digest, version: version)
        let db = try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        let books = SwiftDataBookStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        try await persistence.setAccountAuthorization(ownerID: ownerID, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: book.id, ownerID: ownerID, generation: generation, contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(fingerprint, expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: version))
        let acceptance = BookServerAcceptance(sha256: digest, acceptedOperationID: UUID(), acceptedAt: Date(timeIntervalSince1970: 456))
        let permit = try #require(try await persistence.readingPermit(bookID: book.id, ownerID: ownerID, generation: generation))
        #expect(try await persistence.recordServerAcceptance(permit: permit, expectedFingerprint: fingerprint, acceptance: acceptance))
        let displacedManagedURL = root.appendingPathComponent("displaced-sample.epub")
        try FileManager.default.moveItem(at: managedURL, to: displacedManagedURL)

        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: { generation }, currentOwnerID: { ownerID }, managedURL: { root.appendingPathComponent($0.fileURL) })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = BookMaterializationCoordinator(rootURL: root, lifecycle: lifecycle, sourceRegistry: registry, persistence: persistence, bookStore: books, currentGeneration: { generation })
        let storage = BookFileStorage(rootURL: root, bookStore: books, coverExtractors: [:], metadataExtractors: [:],
                                      fingerprintPersistence: persistence, fingerprintAccountGeneration: { generation }, materializationCoordinator: coordinator)
        return MissingSampleFixture(root: root, sourceURL: sourceURL, managedURL: managedURL, displacedManagedURL: displacedManagedURL,
                                    bytes: bytes, generation: generation, db: db, book: book, books: books,
                                    persistence: persistence, registry: registry, coordinator: coordinator, storage: storage, acceptance: acceptance)
    }

    private struct MissingSampleFixture {
        let root: URL
        let sourceURL: URL
        let managedURL: URL
        let displacedManagedURL: URL
        let bytes: Data
        let generation: UInt64
        let db: RishiDBStore
        let book: Book
        let books: SwiftDataBookStore
        let persistence: SwiftDataBookImportPersistence
        let registry: BookSourceRegistry
        let coordinator: BookMaterializationCoordinator
        let storage: BookFileStorage
        let acceptance: BookServerAcceptance
    }
}

private actor ImportsSwapRetryPersistence: BookImportPersistence {
    private let root: URL
    private let outside: URL
    private var pending: PendingBookMaterialization?
    private(set) var reservationCount = 0

    init(root: URL, outside: URL) {
        self.root = root
        self.outside = outside
    }

    func pendingMaterialization(bookID: BookID, ownerID: UserID) async throws -> PendingBookMaterialization? {
        guard pending?.token.bookID == bookID, pending?.token.ownerID == ownerID else { return nil }
        return pending
    }

    func fingerprint(bookID: BookID, ownerID: UserID) async throws -> BookFileFingerprint? { nil }

    func reserveRegistration(book: Book, job: PendingBookMaterialization, candidate: BookImportCandidateSnapshot?) async throws -> BookRegistration {
        reservationCount += 1
        pending = job
        if reservationCount == 2 {
            let imports = root.appendingPathComponent("Imports", isDirectory: true)
            let movedImports = outside.appendingPathComponent("staged-imports", isDirectory: true)
            try FileManager.default.moveItem(at: imports, to: movedImports)
            try FileManager.default.createSymbolicLink(at: imports, withDestinationURL: movedImports)
        }
        let existing = Book(
            id: job.token.bookID, userId: job.token.ownerID,
            title: book.title, author: book.author, formatType: book.formatType,
            fileURL: job.destinationRelativePath
        )
        return BookRegistration(book: existing, token: job.token, disposition: .retryRequired)
    }

    func joinOrRetryPending(ownerID: UserID, sha256: String, newSource: PendingBookMaterialization, retiredAttempt: RetiredBookMaterializationAttempt?) async throws -> BookRegistration? { nil }
    func transition(token: BookMaterializationToken, from: BookMaterializationPhase, to: BookMaterializationPhase) async throws -> Bool { false }
    func commitManaged(token: BookMaterializationToken, fingerprint: BookFileFingerprint) async throws -> Bool { false }
    func patchCover(bookID: BookID, token: BookMaterializationToken, relativePath: String) async throws -> Bool { false }
    func adoptRecovery(expectedToken: BookMaterializationToken, currentOwnerID: UserID, currentGeneration: UInt64, newAttemptID: UUID, verifiedArtifacts: VerifiedBookArtifacts) async throws -> BookMaterializationToken? { nil }
    func pendingMaterializationForRecovery(bookID: BookID, ownerID: UserID, currentGeneration: UInt64) async throws -> PendingBookMaterialization? {
        guard pending?.token.bookID == bookID, pending?.token.ownerID == ownerID else { return nil }
        return pending
    }
    func setAccountAuthorization(ownerID: UserID, generation: UInt64?) async throws {}
    func setBookReadingAuthorization(bookID: BookID, ownerID: UserID, generation: UInt64, contentRevision: UUID, tombstoned: Bool) async throws {}
}
