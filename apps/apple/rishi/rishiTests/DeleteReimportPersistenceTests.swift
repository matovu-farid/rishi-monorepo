import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import rishi

private enum DeleteReimportTestError: Error { case timeout }

@MainActor
private func deleteReimportRun<T: Sendable>(_ action: @escaping @MainActor () async throws -> T) async throws -> T {
    var outcome: Result<T, Error>?
    let task = Task { do { outcome = .success(try await action()) } catch { outcome = .failure(error) } }
    defer { task.cancel() }
    guard await readerLifetimeEventually({ outcome != nil }) else { throw DeleteReimportTestError.timeout }
    return try #require(outcome).get()
}

@MainActor
private struct DeleteReimportFixture {
    let base: ReaderDeletionFixture
    let storage: BookFileStorage
    let coordinator: BookMaterializationCoordinator
    let importer: ImportCoordinator
    let source: URL
    let book: Book
    let library: LibraryViewModel

    static func make(format: BookFormat, copying: Bool = false, copyGate: ReaderLifetimeGate? = nil, durableDeletion: Bool = false) async throws -> Self {
        let base = try await ReaderDeletionFixture.make()
        let sourceRoot = URL.temporaryDirectory.appendingPathComponent("reimport-original-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("original.\(format.rawValue)")
        if format == .pdf { try FixtureBuilders.writeTinyPDF(to: source) }
        else { try await FixtureBuilders.writeTinyEPUB(to: source, withCover: false) }
        // The shared lifetime fixture supplies real stores/account authority;
        // the subject below is imported by the actual managed pipeline.
        try await base.storage.delete(base.book)
        let copier = CoordinatedBookCopier()
        let coordinator = BookMaterializationCoordinator(
            rootURL: base.root, lifecycle: base.lifecycle, sourceRegistry: base.registry,
            persistence: base.persistence, bookStore: base.books, currentGeneration: { base.generation },
            isTombstoned: { (try? await base.metadata.isTombstone(entityId: $0, kind: .book)) ?? true },
            copySelectedSource: { _, lease, staging, hash, bytes, version in
                if let copyGate { await copyGate.wait(cancellationAware: false) }
                return try await copier.copy(source: lease, to: staging, expectedSHA256: hash, expectedByteCount: bytes, sourceVersion: version)
            }
        )
        let storage = BookFileStorage(
            rootURL: base.root, bookStore: base.books, coverExtractors: [:],
            metadataExtractors: ["epub": EpubMetadataExtractor(), "pdf": PDFKitMetadataExtractor()],
            isTombstoned: { (try? await base.metadata.isTombstone(entityId: $0, kind: .book)) ?? true },
            fingerprintPersistence: base.persistence, fingerprintAccountGeneration: { base.generation },
            materializationCoordinator: coordinator
        )
        let importer = ImportCoordinator(storage: storage, currentUserId: { base.owner }, lifecycle: base.lifecycle)
        let book: Book
        if copying {
            book = try await storage.registerSourceReadable(from: source, ownerId: base.owner, accountGeneration: base.generation).book
        } else {
            book = try await storage.importBook(from: source, ownerId: base.owner, expectedContentHash: nil, accountGeneration: base.generation)
        }
        let identity = LibraryAccountIdentity(userID: base.owner, generation: base.generation)
        let library = LibraryViewModel.make(
            bookStore: base.books, userId: base.owner, importCoordinator: importer,
            positionStore: base.positions, bookFileStorage: storage, bookSourceRegistry: base.registry,
            bookImportLifecycle: base.lifecycle, bookMaterializationCoordinator: coordinator,
            currentAccountGeneration: { base.generation }, accountIdentity: identity, currentAccountIdentity: { identity },
            onBookDeleted: { try await base.sync.markBookDeleted($0) },
            syncEngine: durableDeletion ? base.sync : nil
        )
        await library.refresh()
        await library.waitForHydration()
        return Self(base: base, storage: storage, coordinator: coordinator, importer: importer, source: source, book: book, library: library)
    }
}

/// Generation advances independently of the outgoing owner, matching account
/// transition's persisted-generation-first ordering.
private final class DeleteReimportAccountState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 71
    private var admitted: [UInt64] = []
    var generation: UInt64 { lock.withLock { value } }
    var admissions: [UInt64] { lock.withLock { admitted } }
    func advance() { lock.withLock { value += 1 } }
    func recordAdmission(_ generation: UInt64) { lock.withLock { admitted.append(generation) } }
}

private final class DeleteReimportDownloadProtocol: MockURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static let _storage = MockURLProtocolStorage()
    override class var storage: MockURLProtocolStorage { _storage }
    static var handler: (@Sendable (URLRequest) throws -> (Int, Data, [String: String]?))? {
        get { storage.handler }
        set { storage.handler = newValue }
    }
    static func reset() { storage.reset() }
}

private final class DeleteReimportRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var events: [String] { lock.withLock { values } }
    func record(_ value: String) { lock.withLock { values.append(value) } }
}

private struct DeleteReimportChapterPersistence: ChapterIndexPersistence {
    let books: SwiftDataBookStore
    func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? { try await books.chapterIndex(bookID: bookID, contentVersion: contentVersion) }
    func upsertChapterIndex(_ index: ChapterIndex) async throws { try await books.upsertChapterIndex(index) }
    func markChapterIndexDirty(bookID: BookID) async throws {}
}

@MainActor
private func deleteReimportSyncGraph(_ fixture: ReaderDeletionFixture, client: WorkerClient, session: URLSession) -> (SyncEngine, OutboundDrainer, SyncQueue, BookReadinessPolicy) {
    let queue = SyncQueue(metadataStore: fixture.metadata)
    let highlights = SwiftDataHighlightStore(dbStore: fixture.db)
    let bookmarks = SwiftDataBookmarkStore(dbStore: fixture.db)
    let conversations = SwiftDataConversationStore(dbStore: fixture.db)
    let messages = SwiftDataMessageStore(dbStore: fixture.db)
    let chapters = DeleteReimportChapterPersistence(books: fixture.books)
    let booksUploader = BookUploader(workerClient: client, metadataStore: fixture.metadata, fileStorage: fixture.storage, urlSession: session, userIdProvider: { fixture.owner.uuidString })
    let positionsUploader = PositionUploader(workerClient: client, positionStore: fixture.positions, bookStore: fixture.books, metadataStore: fixture.metadata)
    let highlightsUploader = HighlightUploader(workerClient: client, highlightStore: highlights, metadataStore: fixture.metadata)
    let bookmarksUploader = BookmarkUploader(workerClient: client, bookmarkStore: bookmarks, metadataStore: fixture.metadata)
    let conversationsUploader = ConversationUploader(workerClient: client, conversationStore: conversations, metadataStore: fixture.metadata)
    let messagesUploader = MessageUploader(workerClient: client, messageStore: messages, metadataStore: fixture.metadata)
    let chaptersUploader = ChapterIndexUploader(workerClient: client, bookStore: fixture.books, persistence: chapters, metadataStore: fixture.metadata)
    let policy = BookReadinessPolicy(bookStore: fixture.books, positionStore: fixture.positions, highlightStore: highlights, bookmarkStore: bookmarks, conversationStore: conversations, messageStore: messages, chapterIndexes: chapters, metadataStore: fixture.metadata, sourceResolver: fixture.registry, currentUserID: { fixture.owner })
    let engine = SyncEngine(dependencies: .init(queue: queue, metadataStore: fixture.metadata, bookStore: fixture.books,
        bookUploader: booksUploader, positionUploader: positionsUploader, highlightUploader: highlightsUploader,
        conversationUploader: conversationsUploader, messageUploader: messagesUploader, bookmarkUploader: bookmarksUploader,
        chapterIndexUploader: chaptersUploader, fetcher: RemoteChangeFetcher(workerClient: client, metadataStore: fixture.metadata),
        applier: ChangeApplier(
            bookStore: fixture.books,
            positionStore: fixture.positions,
            highlightStore: highlights,
            bookmarkStore: bookmarks,
            metadataStore: fixture.metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                return integration
            }()
        ),
        conversationsFetcher: ConversationsFetcher(workerClient: client, metadataStore: fixture.metadata), messagesFetcher: MessagesFetcher(workerClient: client, metadataStore: fixture.metadata), conversationStore: conversations, messageStore: messages, currentUserId: { fixture.owner }, bookReadinessPolicy: policy))
    let drainer = OutboundDrainer(dependencies: .init(queue: queue, bookStore: fixture.books, metadataStore: fixture.metadata,
        bookUploader: booksUploader, positionUploader: positionsUploader, highlightUploader: highlightsUploader,
        conversationUploader: conversationsUploader, messageUploader: messagesUploader, bookmarkUploader: bookmarksUploader,
        chapterIndexUploader: chaptersUploader, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(), currentUserId: { fixture.owner }, readinessPolicy: policy))
    return (engine, drainer, queue, policy)
}

@Suite("Durable deletion and same-file reimport", .serialized)
@MainActor
struct DeleteReimportPersistenceTests {
    @Test("logical deletion and same-file reimport finish while the old reader and effect remain held")
    func logicalDeletionBeforeHeldSourceRelease() async throws {
        let fixture = try await deleteReimportRun { try await DeleteReimportFixture.make(format: .epub, durableDeletion: true) }
        let closeGate = ReaderLifetimeGate()
        var borrower: BookSourceLease? = try await fixture.base.registry.acquireReadableSource(for: fixture.book)
        var effect: SourceEffectAdmission? = try borrower?.effectAuthority.admit(try #require(borrower).sourceAccessPermit)
        defer { closeGate.open(); effect?.release(); borrower = nil }
        let oldPath = fixture.base.root.appendingPathComponent(fixture.book.fileURL)
        let operation = try #require(fixture.library.beginDeletion(fixture.book))
        var completed = false
        let deletion = Task {
            await fixture.library.completeDeletion(operation, closePresentedReader: { _ in await closeGate.wait(cancellationAware: false) })
            completed = true
        }
        defer { deletion.cancel() }
        #expect(await readerLifetimeEventually { completed })
        guard completed else { return }
        #expect(fixture.library.deletionError == nil)
        #expect(fixture.library.books.isEmpty)
        #expect(try await fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.base.books.book(fixture.book.id) == nil)
        #expect(try await fixture.base.persistence.isBookPermanentlyDeleted(bookID: fixture.book.id, ownerID: fixture.base.owner))
        #expect(FileManager.default.fileExists(atPath: oldPath.path))

        let imported = try await deleteReimportRun { await fixture.library.importPicked([fixture.source]) }
        let fresh = try #require(imported.first?.book)
        #expect(imported.first?.failureReason == nil)
        #expect(fresh.id != fixture.book.id)
        let ready = try await deleteReimportRun { try await fixture.base.registry.awaitManagedSource(for: fresh) }
        var freshLease: BookSourceLease? = try await fixture.base.registry.acquireReadableSource(for: fresh)
        let freshEffect = try #require(freshLease).effectAuthority.admit(try #require(freshLease).sourceAccessPermit)
        freshEffect.release(); freshLease = nil
        #expect(FileManager.default.fileExists(atPath: oldPath.path))
        #expect(FileManager.default.fileExists(atPath: ready.url.path))
        let reopened = try RishiDB.makeStore(at: fixture.base.databaseURL)
        let reopenedBooks = SwiftDataBookStore(dbStore: reopened)
        let reopenedMetadata = try await ReaderDeletionFixture.makeMetadata(at: fixture.base.metadataURL)
        #expect(try await reopenedBooks.book(fixture.book.id) == nil)
        #expect(try await reopenedBooks.book(fresh.id) != nil)
        #expect(try await reopenedMetadata.isTombstone(entityId: fixture.book.id, kind: .book))

        closeGate.open()
        #expect(FileManager.default.fileExists(atPath: oldPath.path))
        effect?.release(); effect = nil; borrower = nil
        #expect(await readerLifetimeEventually { !FileManager.default.fileExists(atPath: oldPath.path) })
        #expect(FileManager.default.fileExists(atPath: ready.url.path))
        var cleanupFinished = false
        let cleanupProbe = Task {
            while !Task.isCancelled {
                if try await fixture.base.persistence.pendingMaterializationForDeletionCleanup(bookID: fixture.book.id, ownerID: fixture.base.owner) == nil {
                    cleanupFinished = true
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { cleanupProbe.cancel() }
        #expect(await readerLifetimeEventually { cleanupFinished })
        #expect(try await fixture.base.books.book(fresh.id) != nil)
    }

    @Test("retiring real imports show retryable errors and completed deletion reimports a fresh readable identity",
          arguments: [BookFormat.epub, .pdf], ["managed", "missing", "copying"])
    func retirementAndReimport(format: BookFormat, phase: String) async throws {
        let copyGate = phase == "copying" ? ReaderLifetimeGate() : nil
        defer { copyGate?.open() }
        let fixture = try await deleteReimportRun { try await DeleteReimportFixture.make(format: format, copying: phase == "copying", copyGate: copyGate) }
        if let copyGate { #expect(await readerLifetimeEventually { copyGate.entered > 0 }) }
        var borrower: BookSourceLease? = try await fixture.base.registry.acquireReadableSource(for: fixture.book)
        var effect: SourceEffectAdmission? = try borrower?.effectAuthority.admit(try #require(borrower).sourceAccessPermit)
        defer { effect?.release(); borrower = nil; copyGate?.open() }
        let path = fixture.base.root.appendingPathComponent(fixture.book.fileURL)
        if phase == "missing" { try FileManager.default.removeItem(at: path) }
        let operation = try #require(fixture.library.beginDeletion(fixture.book))
        var deleted = false
        let deletion = Task { await fixture.library.completeDeletion(operation); deleted = true }
        defer { deletion.cancel() }
        #expect(await readerLifetimeEventually { fixture.coordinator.isBookRetiredForDeletion(ownerID: fixture.base.owner, generation: fixture.base.generation, bookID: fixture.book.id) })
        #expect(!deleted)
        #expect(try await !fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.base.books.book(fixture.book.id) != nil)
        #expect(FileManager.default.fileExists(atPath: path.path) == (phase == "managed"))

        let failed = try await deleteReimportRun { await fixture.library.importPicked([fixture.source]) }
        #expect(failed.count == 1)
        #expect(failed.first?.book == nil)
        #expect(failed.first?.failureReason == .deletionInProgress)
        #expect(fixture.library.importError?.message == "This book is still being deleted. Try importing it again when deletion finishes.")
        do {
            _ = try await deleteReimportRun { try await fixture.storage.importBook(from: fixture.source, ownerId: fixture.base.owner, expectedContentHash: nil, accountGeneration: fixture.base.generation) }
            Issue.record("A retired identity was reused by managed import")
        } catch let error as BookImportFailure { #expect(error == .deletionInProgress) }
        #expect(try await fixture.base.books.books(for: fixture.base.owner).map(\.id) == [fixture.book.id])
        #expect(fixture.library.books.isEmpty)
        #expect(!deleted)

        effect?.release(); effect = nil; borrower = nil; copyGate?.open()
        #expect(await readerLifetimeEventually { deleted })
        guard deleted else { return }
        #expect(fixture.library.deletionError == nil)
        #expect(try await fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.base.books.book(fixture.book.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let retry = try await deleteReimportRun { await fixture.library.importPicked([fixture.source]) }
        let fresh = try #require(retry.first?.book)
        #expect(fresh.id != fixture.book.id)
        #expect(retry.first?.failureReason == nil)
        #expect(fixture.library.importError == nil)
        let ready = try await deleteReimportRun { try await fixture.base.registry.awaitManagedSource(for: fresh) }
        #expect(ready.readingPermit.bookID == fresh.id)
        #expect(ready.readingPermit.accountGeneration == fixture.base.generation)
        #expect(FileManager.default.fileExists(atPath: ready.url.path))
        var freshLease: BookSourceLease? = try await fixture.base.registry.acquireReadableSource(for: fresh)
        let freshEffect = try #require(freshLease).effectAuthority.admit(try #require(freshLease).sourceAccessPermit)
        freshEffect.release(); freshLease = nil
        let reopened = try RishiDB.makeStore(at: fixture.base.databaseURL)
        let reopenedBooks = SwiftDataBookStore(dbStore: reopened)
        let reopenedMetadata = try await ReaderDeletionFixture.makeMetadata(at: fixture.base.metadataURL)
        #expect(try await reopenedBooks.book(fixture.book.id) == nil)
        #expect(try await reopenedBooks.book(fresh.id) != nil)
        #expect(try await reopenedMetadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await !reopenedMetadata.isTombstone(entityId: fresh.id, kind: .book))
    }

    @Test("real final source validation reports retirement that starts while its source check is suspended")
    func retirementDuringFinalSourceValidation() async throws {
        let fixture = try await deleteReimportRun { try await DeleteReimportFixture.make(format: .epub) }
        let validationGate = ReaderLifetimeGate()
        let storage = BookFileStorage(rootURL: fixture.base.root, bookStore: fixture.base.books,
            coverExtractors: [:], metadataExtractors: ["epub": EpubMetadataExtractor()],
            isTombstoned: { id in
                await validationGate.wait()
                return (try? await fixture.base.metadata.isTombstone(entityId: id, kind: .book)) ?? true
            },
            fingerprintPersistence: fixture.base.persistence, fingerprintAccountGeneration: { fixture.base.generation },
            materializationCoordinator: fixture.coordinator)
        var borrower: BookSourceLease? = try await fixture.base.registry.acquireReadableSource(for: fixture.book)
        var effect: SourceEffectAdmission? = try borrower?.effectAuthority.admit(try #require(borrower).sourceAccessPermit)
        defer { validationGate.open(); effect?.release(); borrower = nil }
        let registration = SourceReadableBookRegistration(book: fixture.book, state: .managed)
        var outcome: Result<Void, Error>?
        let validation = Task {
            do { try await storage.checkedValidateSourceReadableRegistration(registration, ownerId: fixture.base.owner, accountGeneration: fixture.base.generation); outcome = .success(()) }
            catch { outcome = .failure(error) }
        }
        defer { validation.cancel() }
        #expect(await readerLifetimeEventually { validationGate.entered > 0 })
        let operation = try #require(fixture.library.beginDeletion(fixture.book))
        var deleted = false
        let deletion = Task { await fixture.library.completeDeletion(operation); deleted = true }
        defer { deletion.cancel() }
        #expect(await readerLifetimeEventually { fixture.coordinator.isBookRetiredForDeletion(ownerID: fixture.base.owner, generation: fixture.base.generation, bookID: fixture.book.id) })
        validationGate.open()
        #expect(await readerLifetimeEventually { outcome != nil })
        switch try #require(outcome) {
        case .success: Issue.record("Final validation accepted a retired source")
        case .failure(let error): #expect(error as? BookImportFailure == .deletionInProgress)
        }
        #expect(!deleted)
        #expect(try await !fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        effect?.release(); effect = nil; borrower = nil
        #expect(await readerLifetimeEventually { deleted })
        #expect(try await fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
    }

    @Test("concurrent identical imports after durable deletion reserve one fresh managed identity", arguments: [BookFormat.epub, .pdf])
    func concurrentReimportAfterDeletion(format: BookFormat) async throws {
        let fixture = try await deleteReimportRun { try await DeleteReimportFixture.make(format: format) }
        let operation = try #require(fixture.library.beginDeletion(fixture.book))
        try await deleteReimportRun { await fixture.library.completeDeletion(operation) }
        #expect(try await fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        let outcomes = try await deleteReimportRun {
            await fixture.importer.registerSourceReadableBooks([fixture.source, fixture.source])
        }
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.failureReason == nil && $0.error == nil })
        let fresh = try #require(outcomes.first?.book)
        #expect(fresh.id != fixture.book.id)
        #expect(outcomes.compactMap(\.book).allSatisfy { $0.id == fresh.id })
        let managed = try await deleteReimportRun { try await fixture.base.registry.awaitManagedSource(for: fresh) }
        #expect(managed.readingPermit.bookID == fresh.id)
        #expect(try await fixture.base.books.books(for: fixture.base.owner).map(\.id) == [fresh.id])
        #expect(try await fixture.base.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
    }

    @Test("clean acknowledged tombstones reject older and newer live inbound payloads without R2", arguments: [-1.0, 1.0])
    func acknowledgedDeletionRejectsLiveReplay(offset: Double) async throws {
        let fixture = try await deleteReimportRun { try await DeleteReimportFixture.make(format: .epub) }
        let operation = try #require(fixture.library.beginDeletion(fixture.book))
        try await deleteReimportRun { await fixture.library.completeDeletion(operation) }
        let dirtyAt = try await fixture.base.metadata.dirtyAt(entityId: fixture.book.id, kind: .book)
        let accepted = Date()
        #expect(try await fixture.base.metadata.acknowledgeTombstoneIfUnchanged(entityId: fixture.book.id, kind: .book, expectedDirtyAt: dirtyAt, lastSyncedAt: accepted, remoteEtag: nil))
        let metadata = try await ReaderDeletionFixture.makeMetadata(at: fixture.base.metadataURL)
        let db = try RishiDB.makeStore(at: fixture.base.databaseURL)
        let books = SwiftDataBookStore(dbStore: db)
        let positions = SwiftDataPositionStore(dbStore: db)
        let applier = ChangeApplier(
            bookStore: books,
            positionStore: positions,
            highlightStore: SwiftDataHighlightStore(dbStore: db),
            bookmarkStore: SwiftDataBookmarkStore(dbStore: db),
            metadataStore: metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                integration.userIdProvider = { fixture.base.owner }
                return integration
            }()
        )
        let payload = try SyncPayloadCodec.encodeBook(fixture.book, position: Position(bookId: fixture.book.id, locator: "epub-v1:replayed", percentComplete: 0.5, updatedAt: accepted))
        let replay = SyncChange(kind: SyncEntityKind.book.rawValue, id: fixture.book.id, payload: payload, updatedAt: accepted.addingTimeInterval(offset), deleted: false)
        let result = await applier.apply([replay], expectedUserId: fixture.base.owner)
        #expect(result.applied == 0)
        #expect(result.conflicts == 1)
        #expect(result.errors.isEmpty)
        #expect(try await books.book(fixture.book.id) == nil)
        #expect(try await positions.position(for: fixture.book.id) == nil)
        #expect(try await metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await metadata.remoteSeenAt(entityId: fixture.book.id, kind: .book) == replay.updatedAt)
        let reimport = try await deleteReimportRun { try await fixture.storage.importBook(from: fixture.source, ownerId: fixture.base.owner, expectedContentHash: nil, accountGeneration: fixture.base.generation) }
        #expect(reimport.id != fixture.book.id)
        #expect(try await metadata.isTombstone(entityId: fixture.book.id, kind: .book))
    }

    @Test("late dirty marks and resident acknowledged tombstones never retry; pending deletion still uploads", arguments: ["late", "resident", "pending"])
    func acknowledgedTombstoneQueueDisposition(stage: String) async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let requests = DeleteReimportRequestProbe()
        DeleteReimportDownloadProtocol.handler = { request in
            requests.record("\(request.httpMethod ?? "missing-method") \(request.url?.path ?? "missing-path")")
            return (200, Data("{\"accepted_at\":946684800,\"accepted\":true}".utf8), nil)
        }
        defer { DeleteReimportDownloadProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteReimportDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = WorkerClient(baseURL: URL(string: "https://queue.example.invalid")!, session: session, tokenProvider: StaticTokenProvider("fixture-token"), dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        let (engine, drainer, queue, policy) = deleteReimportSyncGraph(fixture, client: client, session: session)
        let id = UUID()
        if stage == "late" { try await fixture.metadata.markTombstone(entityId: id, kind: .book) }
        else { try await engine.markBookDeleted(id) }
        let dirtyAt = try #require(try await fixture.metadata.dirtyAt(entityId: id, kind: .book))
        let operation = try #require(try await fixture.metadata.operationId(entityId: id, kind: .book))
        if stage != "pending" {
            #expect(try await fixture.metadata.acknowledgeTombstoneIfCurrent(entityId: id, kind: .book, expectedDirtyAt: dirtyAt, expectedOperationId: operation, lastSyncedAt: Date(), remoteEtag: nil))
        }
        #expect(await engine.markBookDirty(id) == (stage == "pending"))
        #expect(await queue.pendingCount() == (stage == "late" ? 0 : 1))
        #expect(try await policy.classify(SyncQueueItem(entityId: id, kind: .book)) == (stage == "pending" ? .eligible : .discard))
        if stage == "pending" {
            #expect(try await fixture.metadata.dirtyAt(entityId: id, kind: .book) == dirtyAt)
            #expect(try await fixture.metadata.operationId(entityId: id, kind: .book) == operation)
        }
        let drained = try await deleteReimportRun { await drainer.drain(limit: 10, expectedUserId: fixture.owner) }
        #expect(drained.errors.isEmpty)
        #expect(drained.booksUploaded == (stage == "pending" ? 1 : 0))
        // markBookDeleted also schedules an inbound wave. Join its finite
        // fixture work before inspecting requests or resetting the transport.
        if stage != "late" { await engine.requestSyncAndWait() }
        let allowedRequests: Set<String> = [
            "GET /api/sync/events", "GET /api/sync/changes",
            "GET /api/sync/conversations", "GET /api/sync/messages",
            "POST /api/sync/push"
        ]
        let expectedPushes = stage == "pending" ? ["POST /api/sync/push"] : []
        #expect(requests.events.allSatisfy { allowedRequests.contains($0) })
        #expect(requests.events.filter { $0 == "POST /api/sync/push" } == expectedPushes)
        #expect(await queue.pendingCount() == 0)
        #expect(try await fixture.metadata.isTombstone(entityId: id, kind: .book))
        #expect(try await fixture.metadata.dirtyAt(entityId: id, kind: .book) == nil)
        let repeated = try await deleteReimportRun { await drainer.drain(limit: 10, expectedUserId: fixture.owner) }
        #expect(repeated.errors.isEmpty)
        #expect(repeated.booksUploaded == 0)
        #expect(requests.events.filter { $0 == "POST /api/sync/push" } == expectedPushes)
        #expect(await engine.markBookDirty(fixture.book.id))
        #expect(await queue.pendingCount() == 1)
        #expect(try await !fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
    }

    @Test("live download replacement stays readable and preserves an already held local deletion witness", arguments: [false, true])
    func liveSourceReplacementRespectsDeletion(retiring: Bool) async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let work = DeleteReimportRequestProbe()
        let lifecycle = BookImportLifecycle(sourceRegistry: fixture.registry, currentAccountGeneration: { fixture.generation },
            cancelBookWork: { _, _, _ in work.record("cancel") }, drainBookWork: { _, _, _ in work.record("drain") })
        let incoming = retiring ? fixture.book : Book(userId: fixture.owner, title: "New remote book", formatType: .epub, fileURL: "Books/remote.epub")
        let permit = AccountMutationPermit(ownerID: fixture.owner, accountGeneration: fixture.generation)
        let bytes = try Data(contentsOf: fixture.root.appendingPathComponent(fixture.book.fileURL))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var borrower: BookSourceLease?
        var effect: SourceEffectAdmission?
        var witness: BookDeletionRetirementWitness?
        if retiring {
            borrower = try await fixture.registry.acquireReadableSource(for: fixture.book)
            effect = try #require(borrower).effectAuthority.admit(try #require(borrower).sourceAccessPermit)
            witness = lifecycle.retireBookForDeletion(ownerID: fixture.owner, generation: fixture.generation, bookID: fixture.book.id)
        }
        defer { effect?.release(); borrower = nil; DeleteReimportDownloadProtocol.reset() }
        let requests = DeleteReimportRequestProbe()
        DeleteReimportDownloadProtocol.handler = { request in
            requests.record(request.url?.path ?? "missing-path")
            if request.url?.path == "/api/sync/download-url" {
                return (200, Data("{\"url\":\"https://download.example.invalid/book\",\"expires_at\":946684800}".utf8), nil)
            }
            return (200, bytes, ["Content-Type": "application/epub+zip"])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteReimportDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = WorkerClient(baseURL: URL(string: "https://live.example.invalid")!, session: session, tokenProvider: StaticTokenProvider("fixture-token"), dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        let storage = BookFileStorage(rootURL: fixture.root, bookStore: fixture.books, coverExtractors: [:],
            isTombstoned: { (try? await fixture.metadata.isTombstone(entityId: $0, kind: .book)) ?? true }, fingerprintPersistence: fixture.persistence, fingerprintAccountGeneration: { fixture.generation })
        let current: @Sendable (AccountMutationPermit) async -> Bool = { $0 == permit && lifecycle.admits(ownerID: $0.ownerID, generation: $0.accountGeneration) }
        let admission: @Sendable (AccountMutationPermit) async -> BookImportOperationLease? = { captured in
            guard captured == permit else { return nil }
            return lifecycle.admitOwnerOperation(ownerID: captured.ownerID, generation: captured.accountGeneration)
        }
        let downloader = BookDownloadCoordinator(workerClient: client, fileStorage: storage, userIdProvider: { fixture.owner.uuidString }, urlSession: session,
            metadataStore: fixture.metadata, isCurrentAccountPermit: current, admitAccountOperation: admission)
        let applier = ChangeApplier(
            bookStore: fixture.books,
            positionStore: fixture.positions,
            highlightStore: SwiftDataHighlightStore(dbStore: fixture.db),
            bookmarkStore: SwiftDataBookmarkStore(dbStore: fixture.db),
            metadataStore: fixture.metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                integration.userIdProvider = { fixture.owner }
                let fixture_bookMaterializerWithAuthority: (@Sendable (Book, String?, InboundBookFileMetadata?, AccountMutationPermit) async throws -> VerifiedDownloadedBook)? = { book, key, metadata, captured in
                try await downloader.downloadAndMaterializeVerified(book, r2Key: key, expectedRemoteSHA256: metadata?.sha256, expectedRemoteByteCount: metadata?.byteCount, accountPermit: captured)
            }
                let fixture_isCurrentAccountPermit: (@Sendable (AccountMutationPermit) async -> Bool)? = current
                let fixture_admitAccountOperation: (@Sendable (AccountMutationPermit) async -> BookImportOperationLease?)? = admission
                let fixture_prepareBookSourceReplacement: (@Sendable (BookID, AccountMutationPermit) async throws -> BookSourceReplacementToken)? = { id, captured in
                try await lifecycle.prepareBookSourceReplacement(ownerID: captured.ownerID, generation: captured.accountGeneration, bookID: id)
            }
                let fixture_completeBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async throws -> Void)? = { token in
                guard await current(permit), lifecycle.completeBookSourceReplacement(token) else { throw BookImportPromotionError.retired }
            }
                let fixture_abortBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async -> Void)? = { token in
                do {
                    try await fixture.metadata.withLiveBookIdentity(token.bookID) {
                        guard await current(permit) else { throw CancellationError() }
                        lifecycle.abortBookSourceReplacement(token, restoreSource: true)
                    }
                } catch { lifecycle.abortBookSourceReplacement(token, restoreSource: false) }
            }
                let fixture_bookFingerprintPersister: (@Sendable (Book, BookFileFingerprint, UInt64?) async -> Bool)? = { book, fingerprint, generation in
                guard let generation else { return false }
                return await storage.persistVerifiedFingerprint(fingerprint, for: book, expectedGeneration: generation)
            }
                let fixture_managedFingerprintLookup: (@Sendable (Book) async -> BookFileFingerprint?)? = { book in try? await fixture.registry.managedSource(for: book)?.fingerprint }
                let fixture_bookAccountPermitLookup: (@Sendable () async -> AccountMutationPermit?)? = { permit }
                integration.capturePermitOperation = { owner in
                    guard let callback = fixture_bookAccountPermitLookup else { return nil }
                    guard let permit = await callback(), permit.ownerID == owner else { throw BookSyncAccountChanged() }
                    return permit
                }
                integration.validatePermitOperation = { permit in
                    if let callback = fixture_isCurrentAccountPermit {
                        guard let permit, await callback(permit) else { throw BookSyncAccountChanged() }
                    }
                }
                integration.prepareReplacementOperation = { id, permit in
                    guard let callback = fixture_prepareBookSourceReplacement else { return nil }
                    guard let permit else { throw BookSyncAccountChanged() }
                    return try await callback(id, permit)
                }
                integration.completeReplacementOperation = { token in
                    guard let callback = fixture_completeBookSourceReplacement else { throw BookImportPromotionError.retired }
                    try await callback(token)
                }
                integration.abortReplacementOperation = { token in
                    await fixture_abortBookSourceReplacement?(token)
                }
                integration.materializeOperation = { book, key, remote, permit in
                    if let callback = fixture_bookMaterializerWithAuthority {
                        guard let permit else { throw BookSyncAccountChanged() }
                        return try await callback(book, key, remote, permit)
                    }
                    return nil
                }
                integration.admitCommitOperation = { permit in
                    guard let callback = fixture_admitAccountOperation else { return nil }
                    guard let permit, let lease = await callback(permit) else { throw BookSyncAccountChanged() }
                    return lease
                }
                integration.fingerprintOperation = { fingerprint, book, generation in
                    await fixture_bookFingerprintPersister?(book, fingerprint, generation) ?? false
                }
                integration.managedFingerprintOperation = { book in
                    await fixture_managedFingerprintLookup?(book)
                }
                return integration
            }()
        )
        let payload = try SyncPayloadCodec.encodeBook(incoming, r2Key: "owned/remote", fileHash: digest, fileSize: bytes.count)
        let result = try await deleteReimportRun { await applier.apply([SyncChange(kind: SyncEntityKind.book.rawValue, id: incoming.id, payload: payload, updatedAt: Date(), deleted: false)], expectedUserId: fixture.owner) }
        #expect(result.errors.isEmpty)
        if let witness {
            #expect(result.applied == 0)
            #expect(result.conflicts == 1)
            #expect(requests.events.isEmpty)
            #expect(lifecycle.isCurrentDeletionRetirementWitness(witness))
            #expect(lifecycle.isBookRetiredForDeletion(ownerID: fixture.owner, generation: fixture.generation, bookID: incoming.id))
            #expect(lifecycle.admitBookRegistration(ownerID: fixture.owner, generation: fixture.generation, bookID: incoming.id) == nil)
            #expect(try await fixture.books.book(incoming.id) == fixture.book)
            effect?.release(); effect = nil; borrower = nil
            #expect(try await deleteReimportRun { await lifecycle.restoreBookAfterFailedRetirement(witness: witness) })
        } else {
            #expect(result.applied == 1)
            #expect(requests.events == ["/api/sync/download-url", "/book"])
            #expect(work.events == ["cancel", "drain"])
            let canonical = try #require(try await fixture.books.book(incoming.id))
            let managed = try #require(try await fixture.registry.managedSource(for: canonical))
            #expect(managed.readingPermit.accountGeneration == fixture.generation)
            #expect(FileManager.default.fileExists(atPath: managed.url.path))
            let registration = try #require(lifecycle.admitBookRegistration(ownerID: fixture.owner, generation: fixture.generation, bookID: incoming.id))
            registration.release()
            let token = BookMaterializationToken(ownerID: fixture.owner, accountGeneration: fixture.generation, bookID: incoming.id, attemptID: UUID())
            #expect(lifecycle.activatePromotionAttempt(token))
            #expect(try await deleteReimportRun { try await lifecycle.withPromotionPermit(token: token) { true } })
            var readable: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: canonical)
            let entered = try #require(readable).effectAuthority.admit(try #require(readable).sourceAccessPermit)
            entered.release(); readable = nil
        }
    }

    @Test("same-account cancellation restores live replacement gates while deletion and account retirement stay closed",
          arguments: ["prepare", "materializer"], ["live", "deleted", "account"])
    func canceledReplacementCleanup(stage: String, terminal: String) async throws {
        let state = DeleteReimportAccountState()
        let fixture = try await ReaderDeletionFixture.make(currentGeneration: { state.generation })
        let work = DeleteReimportRequestProbe()
        let materializerGate = ReaderLifetimeGate()
        let lifecycle = BookImportLifecycle(sourceRegistry: fixture.registry, currentAccountGeneration: { state.generation },
            cancelBookWork: { _, _, _ in work.record("cancel") }, drainBookWork: { _, _, _ in work.record("drain") })
        let original = AccountMutationPermit(ownerID: fixture.owner, accountGeneration: fixture.generation)
        let current: @Sendable (AccountMutationPermit) async -> Bool = { captured in
            captured == original && captured.accountGeneration == state.generation && lifecycle.admits(ownerID: captured.ownerID, generation: captured.accountGeneration)
        }
        // Factory-equivalent cleanup runs as fresh finite work and joins its
        // actual completion. A canceled caller cannot cancel gate admission.
        let cleanup: @Sendable (BookSourceReplacementToken) async -> Void = { token in
            await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                Task.detached {
                    defer { completion.resume() }
                    let captured = AccountMutationPermit(ownerID: token.ownerID, accountGeneration: token.generation)
                    guard await current(captured),
                          let admitted = lifecycle.admitOwnerOperation(ownerID: captured.ownerID, generation: captured.accountGeneration) else {
                        lifecycle.abortBookSourceReplacement(token, restoreSource: false)
                        return
                    }
                    defer { admitted.release() }
                    do {
                        try await fixture.metadata.withLiveBookIdentity(token.bookID) {
                            guard await current(captured) else { throw CancellationError() }
                            lifecycle.abortBookSourceReplacement(token, restoreSource: true)
                        }
                    } catch { lifecycle.abortBookSourceReplacement(token, restoreSource: false) }
                }
            }
        }
        var borrower: BookSourceLease?
        var effect: SourceEffectAdmission?
        if stage == "prepare" {
            borrower = try await fixture.registry.acquireReadableSource(for: fixture.book)
            effect = try #require(borrower).effectAuthority.admit(try #require(borrower).sourceAccessPermit)
        }
        defer { materializerGate.open(); effect?.release(); borrower = nil }
        let applier = ChangeApplier(
            bookStore: fixture.books,
            positionStore: fixture.positions,
            highlightStore: SwiftDataHighlightStore(dbStore: fixture.db),
            bookmarkStore: SwiftDataBookmarkStore(dbStore: fixture.db),
            metadataStore: fixture.metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                integration.userIdProvider = { fixture.owner }
                let fixture_bookMaterializerWithAuthority: (@Sendable (Book, String?, InboundBookFileMetadata?, AccountMutationPermit) async throws -> VerifiedDownloadedBook)? = { _, _, _, captured in
                #expect(captured == original)
                await materializerGate.wait(cancellationAware: false)
                try Task.checkCancellation()
                throw DeleteReimportTestError.timeout
            }
                let fixture_isCurrentAccountPermit: (@Sendable (AccountMutationPermit) async -> Bool)? = current
                let fixture_prepareBookSourceReplacement: (@Sendable (BookID, AccountMutationPermit) async throws -> BookSourceReplacementToken)? = { id, captured in
                try await lifecycle.prepareBookSourceReplacement(ownerID: captured.ownerID, generation: captured.accountGeneration, bookID: id, onFailure: cleanup)
            }
                let fixture_completeBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async throws -> Void)? = { token in
                guard lifecycle.completeBookSourceReplacement(token) else { throw BookImportPromotionError.retired }
            }
                let fixture_abortBookSourceReplacement: (@Sendable (BookSourceReplacementToken) async -> Void)? = cleanup
                let fixture_bookAccountPermitLookup: (@Sendable () async -> AccountMutationPermit?)? = { original }
                integration.capturePermitOperation = { owner in
                    guard let callback = fixture_bookAccountPermitLookup else { return nil }
                    guard let permit = await callback(), permit.ownerID == owner else { throw BookSyncAccountChanged() }
                    return permit
                }
                integration.validatePermitOperation = { permit in
                    if let callback = fixture_isCurrentAccountPermit {
                        guard let permit, await callback(permit) else { throw BookSyncAccountChanged() }
                    }
                }
                integration.prepareReplacementOperation = { id, permit in
                    guard let callback = fixture_prepareBookSourceReplacement else { return nil }
                    guard let permit else { throw BookSyncAccountChanged() }
                    return try await callback(id, permit)
                }
                integration.completeReplacementOperation = { token in
                    guard let callback = fixture_completeBookSourceReplacement else { throw BookImportPromotionError.retired }
                    try await callback(token)
                }
                integration.abortReplacementOperation = { token in
                    await fixture_abortBookSourceReplacement?(token)
                }
                integration.materializeOperation = { book, key, remote, permit in
                    if let callback = fixture_bookMaterializerWithAuthority {
                        guard let permit else { throw BookSyncAccountChanged() }
                        return try await callback(book, key, remote, permit)
                    }
                    return nil
                }
                return integration
            }()
        )
        let payload = try SyncPayloadCodec.encodeBook(fixture.book, r2Key: "owned/canceled")
        var outcome: ChangeApplier.ApplyResult?
        let request = Task {
            outcome = await applier.apply([SyncChange(kind: SyncEntityKind.book.rawValue, id: fixture.book.id, payload: payload, updatedAt: Date(), deleted: false)], expectedUserId: fixture.owner)
        }
        defer { request.cancel() }
        #expect(await readerLifetimeEventually { stage == "prepare" ? work.events.contains("cancel") : materializerGate.entered > 0 })
        #expect(outcome == nil)
        request.cancel()
        var witness: BookDeletionRetirementWitness?
        if terminal == "deleted" {
            witness = lifecycle.retireBookForDeletion(ownerID: fixture.owner, generation: fixture.generation, bookID: fixture.book.id)
            try await fixture.metadata.markTombstone(entityId: fixture.book.id, kind: .book)
        } else if terminal == "account" {
            _ = lifecycle.fenceAccount(ownerID: fixture.owner, generation: fixture.generation)
            state.advance()
            try await fixture.persistence.setAccountAuthorization(ownerID: fixture.owner, generation: state.generation)
        }
        #expect(outcome == nil)
        effect?.release(); effect = nil; borrower = nil; materializerGate.open()
        #expect(await readerLifetimeEventually { outcome != nil })
        #expect(try #require(outcome).applied == 0)
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        if terminal == "live" {
            #expect(try await !fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
            let ready = try #require(try await fixture.registry.managedSource(for: fixture.book))
            #expect(ready.accountGeneration == fixture.generation)
            let registration = try #require(lifecycle.admitBookRegistration(ownerID: fixture.owner, generation: fixture.generation, bookID: fixture.book.id))
            registration.release()
            let token = BookMaterializationToken(ownerID: fixture.owner, accountGeneration: fixture.generation, bookID: fixture.book.id, attemptID: UUID())
            #expect(lifecycle.activatePromotionAttempt(token))
            #expect(try await deleteReimportRun { try await lifecycle.withPromotionPermit(token: token) { true } })
            var readable: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
            let entered = try #require(readable).effectAuthority.admit(try #require(readable).sourceAccessPermit)
            entered.release(); readable = nil
        } else {
            #expect(lifecycle.admitBookRegistration(ownerID: fixture.owner, generation: fixture.generation, bookID: fixture.book.id) == nil)
            #expect(try await fixture.registry.managedSource(for: fixture.book) == nil)
            if let witness {
                #expect(lifecycle.isCurrentDeletionRetirementWitness(witness))
                #expect(try await fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
            } else {
                try await deleteReimportRun { await lifecycle.drainAccount(fixture.owner, generation: fixture.generation) }
                #expect(lifecycle.activateAccount(ownerID: fixture.owner, generation: state.generation))
                let replacement = try #require(try await fixture.registry.managedSource(for: fixture.book))
                #expect(replacement.accountGeneration == state.generation)
            }
        }
    }

    @Test("old download responses cannot promote under a replacement generation with the same outgoing owner", arguments: ["url", "transport", "gate", "cancel"])
    func downloadRetainsOriginalGeneration(stage: String) async throws {
        let state = DeleteReimportAccountState()
        let fixture = try await ReaderDeletionFixture.make(currentGeneration: { state.generation })
        let incoming = Book(userId: fixture.owner, title: "Downloaded response", formatType: .epub, fileURL: "Books/remote.epub")
        let permit = AccountMutationPermit(ownerID: fixture.owner, accountGeneration: fixture.generation)
        let data = try Data(contentsOf: fixture.root.appendingPathComponent(fixture.book.fileURL))
        let hold = ReaderLifetimeGate()
        let holder = Task {
            if stage == "gate" || stage == "cancel" {
                try? await fixture.metadata.withLiveBookIdentity(incoming.id) { await hold.wait(); return () }
            }
        }
        defer { hold.open(); holder.cancel(); DeleteReimportDownloadProtocol.storage.reset() }
        if stage == "gate" || stage == "cancel" { #expect(await readerLifetimeEventually { hold.entered > 0 }) }
        let advance: @Sendable () -> Void = { [lifecycle = fixture.lifecycle, owner = fixture.owner, generation = fixture.generation] in
            _ = lifecycle.fenceAccount(ownerID: owner, generation: generation)
            state.advance()
        }
        DeleteReimportDownloadProtocol.storage.handler = { request in
            if request.url?.path == "/api/sync/download-url" {
                if stage == "url" { advance() }
                return (200, Data("{\"url\":\"https://download.example.invalid/book\",\"expires_at\":946684800}".utf8), nil)
            }
            if stage == "transport" { advance() }
            return (200, data, ["Content-Type": "application/epub+zip"])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteReimportDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let downloader = BookDownloadCoordinator(
            workerClient: WorkerClient(baseURL: URL(string: "https://worker.example.invalid")!, session: session, tokenProvider: StaticTokenProvider("fixture-token"), dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider()),
            fileStorage: fixture.storage, userIdProvider: { fixture.owner.uuidString }, urlSession: session,
            metadataStore: fixture.metadata,
            isCurrentAccountPermit: { $0.ownerID == fixture.owner && $0.accountGeneration == state.generation && fixture.lifecycle.admits(ownerID: $0.ownerID, generation: $0.accountGeneration) },
            admitAccountOperation: { captured in
                guard captured.ownerID == fixture.owner, captured.accountGeneration == state.generation,
                      let lease = fixture.lifecycle.admitOwnerOperation(ownerID: captured.ownerID, generation: captured.accountGeneration) else { return nil }
                state.recordAdmission(captured.accountGeneration)
                return lease
            }
        )
        var outcome: Result<VerifiedDownloadedBook, Error>?
        let request = Task { do { outcome = .success(try await downloader.downloadAndMaterializeVerified(incoming, r2Key: "owned/book", accountPermit: permit)) } catch { outcome = .failure(error) } }
        defer { request.cancel() }
        if stage == "gate" || stage == "cancel" {
            #expect(await readerLifetimeEventually { !state.admissions.isEmpty })
            if stage == "cancel" { request.cancel() } else { advance() }; hold.open()
        }
        #expect(await readerLifetimeEventually { outcome != nil })
        let result = try #require(outcome)
        if case .success = result { Issue.record("Old response promoted using replacement account authority") }
        #expect(state.generation == fixture.generation + (stage == "cancel" ? 0 : 1))
        #expect(state.admissions == (["gate", "cancel"].contains(stage) ? [fixture.generation] : []))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Books/\(incoming.id)").path))
        #expect(try await fixture.books.book(incoming.id) == nil)
        #expect(try await fixture.persistence.fingerprint(bookID: incoming.id, ownerID: fixture.owner) == nil)
        if stage == "cancel" { advance() }
        try await deleteReimportRun { await fixture.lifecycle.drainAccount(fixture.owner, generation: fixture.generation) }
        try await fixture.persistence.setAccountAuthorization(ownerID: fixture.owner, generation: state.generation)
        #expect(fixture.lifecycle.activateAccount(ownerID: fixture.owner, generation: state.generation))
        let current = try #require(try await fixture.registry.managedSource(for: fixture.book))
        #expect(current.accountGeneration == state.generation)
    }
}
