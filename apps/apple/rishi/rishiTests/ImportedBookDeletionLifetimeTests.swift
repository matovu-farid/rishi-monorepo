import CryptoKit
import Foundation
import ReadiumShared
import SwiftData
import SwiftUI
import Testing
@testable import rishi

/// Shared by the native lifetime suites: every source is acquired through the
/// managed registry, with the same fingerprint and authorization as an import.
/// Isolated directories remain in temporary storage for OS cleanup: deleting a
/// live SwiftData container's backing files triggers SQLite vnode warnings.
@MainActor
struct ReaderDeletionFixture {
    let root: URL
    let databaseURL: URL
    let metadataURL: URL
    let owner: UserID
    let generation: UInt64
    let book: Book
    let db: RishiDBStore
    let books: SwiftDataBookStore
    let positions: SwiftDataPositionStore
    let persistence: SwiftDataBookImportPersistence
    let registry: BookSourceRegistry
    let lifecycle: BookImportLifecycle
    let storage: BookFileStorage
    let metadata: SwiftDataSyncMetadataStore
    let sync: SyncEngine

    static func make(currentGeneration: (@Sendable () async -> UInt64)? = nil) async throws -> Self {
        let root = URL.temporaryDirectory.appendingPathComponent("reader-deletion-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("books.sqlite")
        let metadataURL = root.appendingPathComponent("sync.sqlite")
        let owner = UUID()
        let generation: UInt64 = 71
        let id = UUID()
        let book = Book(id: id, userId: owner, title: "Imported lifetime fixture", formatType: .epub,
                        fileURL: "Books/\(id)/\(id).epub")
        let managedURL = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await FixtureBuilders.writeTinyEPUB(to: managedURL, withCover: false)
        let db = try RishiDB.makeStore(at: databaseURL)
        let books = SwiftDataBookStore(dbStore: db)
        let positions = SwiftDataPositionStore(dbStore: db)
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: root)
        try await books.upsert(book)
        let revision = UUID()
        let version = try #require(try FileManagedFileVersionInspector().managedFileVersion(at: managedURL, materializationRevision: revision))
        let digest = SHA256.hash(data: try Data(contentsOf: managedURL)).map { String(format: "%02x", $0) }.joined()
        try await persistence.setAccountAuthorization(ownerID: owner, generation: generation)
        try await persistence.setBookReadingAuthorization(bookID: id, ownerID: owner, generation: generation,
                                                         contentRevision: revision, tombstoned: false)
        #expect(try await persistence.cacheManagedFingerprint(
            BookFileFingerprint(bookID: id, ownerID: owner, sha256: digest, version: version),
            expectedGeneration: generation, expectedRelativePath: book.fileURL, expectedVersion: version
        ))
        let generationProvider: @Sendable () async -> UInt64 = currentGeneration ?? { generation }
        let registry = BookSourceRegistry(persistence: persistence, currentGeneration: generationProvider,
                                          currentOwnerID: { owner }, managedURL: { root.appendingPathComponent($0.fileURL) })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: generationProvider)
        let metadata = try await makeMetadata(at: metadataURL)
        let storage = BookFileStorage(rootURL: root, bookStore: books, coverExtractors: [:],
                                      isTombstoned: { (try? await metadata.isTombstone(entityId: $0, kind: .book)) ?? true })
        let sync = makeSync(db: db, books: books, positions: positions, storage: storage, metadata: metadata)
        return Self(root: root, databaseURL: databaseURL, metadataURL: metadataURL, owner: owner,
                    generation: generation, book: book, db: db, books: books, positions: positions,
                    persistence: persistence, registry: registry, lifecycle: lifecycle,
                    storage: storage, metadata: metadata, sync: sync)
    }

    static func makeMetadata(at url: URL) async throws -> SwiftDataSyncMetadataStore {
        let container = try ModelContainer(for: SyncMetadataRow.self, SyncCursorStateRow.self, SyncRecoveryStateRow.self,
                                           configurations: ModelConfiguration(url: url))
        return await SwiftDataSyncMetadataStore.make(container: container)
    }

    private static func makeSync(db: RishiDBStore, books: SwiftDataBookStore, positions: SwiftDataPositionStore,
                                 storage: BookFileStorage, metadata: SwiftDataSyncMetadataStore) -> SyncEngine {
        let client = WorkerClient(baseURL: URL(string: "https://reader-lifetime.example.invalid")!,
                                  tokenProvider: StaticTokenProvider(nil), dataUseConsentProvider: NoWorkerDataUseConsentProvider())
        let highlights = SwiftDataHighlightStore(dbStore: db)
        let bookmarks = SwiftDataBookmarkStore(dbStore: db)
        let conversations = SwiftDataConversationStore(dbStore: db)
        let messages = SwiftDataMessageStore(dbStore: db)
        let queue = SyncQueue(metadataStore: metadata)
        let chapterIndexPersistence = ReaderDeletionChapterIndexPersistence(
            store: books,
            metadataStore: metadata,
            queue: queue
        )
        return SyncEngine(dependencies: .init(
            queue: queue, metadataStore: metadata, bookStore: books,
            bookUploader: BookUploader(workerClient: client, metadataStore: metadata, fileStorage: storage, userIdProvider: { nil }),
            positionUploader: PositionUploader(workerClient: client, positionStore: positions, bookStore: books, metadataStore: metadata),
            highlightUploader: HighlightUploader(workerClient: client, highlightStore: highlights, metadataStore: metadata),
            conversationUploader: ConversationUploader(workerClient: client, conversationStore: conversations, metadataStore: metadata),
            messageUploader: MessageUploader(workerClient: client, messageStore: messages, metadataStore: metadata),
            bookmarkUploader: BookmarkUploader(workerClient: client, bookmarkStore: bookmarks, metadataStore: metadata),
            chapterIndexUploader: ChapterIndexUploader(
                workerClient: client,
                bookStore: books,
                persistence: chapterIndexPersistence,
                metadataStore: metadata
            ),
            fetcher: RemoteChangeFetcher(workerClient: client, metadataStore: metadata),
            applier: ChangeApplier(
            bookStore: books,
            positionStore: positions,
            highlightStore: highlights,
            bookmarkStore: bookmarks,
            metadataStore: metadata,
            bookIntegration: {
                var integration = TestBookSyncIntegration()
                return integration
            }()
        ),
            conversationsFetcher: ConversationsFetcher(workerClient: client, metadataStore: metadata),
            messagesFetcher: MessagesFetcher(workerClient: client, metadataStore: metadata),
            conversationStore: conversations, messageStore: messages, dataUseConsentProvider: NoWorkerDataUseConsentProvider()
        ))
    }

    func makeLibrary(
        currentAccountGeneration: (@Sendable () async -> UInt64?)? = nil,
        currentAccountIdentity: (@MainActor () -> LibraryAccountIdentity?)? = nil
    ) -> LibraryViewModel {
        let identity = LibraryAccountIdentity(userID: owner, generation: generation)
        let generationProvider: @Sendable () async -> UInt64? = currentAccountGeneration ?? { generation }
        let identityProvider: @MainActor () -> LibraryAccountIdentity? = currentAccountIdentity ?? { identity }
        let engine = sync
        return LibraryViewModel.make(
            bookStore: books, userId: owner,
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { owner }),
            positionStore: positions, bookFileStorage: storage, bookSourceRegistry: registry,
            bookImportLifecycle: lifecycle, currentAccountGeneration: generationProvider,
            accountIdentity: identity, currentAccountIdentity: identityProvider,
            onBookDeleted: { try await engine.markBookDeleted($0) }
        )
    }

    func makeReader(lease: BookSourceLease) -> ReaderViewModel {
        ReaderViewModel(book: book, userId: owner, documentURL: lease.url, positionStore: positions,
                        sourceLifetime: lease, sourceAccessPermit: lease.sourceAccessPermit,
                        sourceEffects: lease.effectAuthority, sourceInvalidationSignal: lease.owner.invalidation)
    }

    static func locator(_ progression: Double = 0.3) throws -> Locator {
        Locator(href: try #require(RelativeURL(path: "OEBPS/nav.xhtml")), mediaType: .xhtml,
                locations: .init(progression: progression, totalProgression: progression))
    }
}

/// Mirrors the application's service-graph adapter while delegating chapter
/// data to the same SwiftData store and dirty state to the fixture's real sync
/// metadata store and queue.
private struct ReaderDeletionChapterIndexPersistence: ChapterIndexPersistence {
    let store: SwiftDataBookStore
    let metadataStore: SwiftDataSyncMetadataStore
    let queue: SyncQueue

    func chapterIndex(bookID: BookID, contentVersion: String) async throws -> ChapterIndex? {
        try await store.chapterIndex(bookID: bookID, contentVersion: contentVersion)
    }

    func upsertChapterIndex(_ index: ChapterIndex) async throws {
        try await store.upsertChapterIndex(index)
    }

    func markChapterIndexDirty(bookID: BookID) async throws {
        try await metadataStore.markDirty(entityId: bookID, kind: .chapterIndex)
        await queue.enqueue(SyncQueueItem(entityId: bookID, kind: .chapterIndex))
    }
}

/// A continuation gate whose entered state is polled with a bounded deadline.
/// Cancellation resumes poll waits; committed effects can deliberately ignore
/// cancellation until the test releases their legitimate admission.
@MainActor
final class ReaderLifetimeGate {
    private(set) var entered = 0
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait(cancellationAware: Bool = true) async {
        entered += 1
        guard !isOpen else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen || (cancellationAware && Task.isCancelled) { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            guard cancellationAware else { return }
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Armed after reader-close admission: the VM's next generation lookup
/// succeeds, then the production factory lookup waits for account replacement.
@MainActor
private final class ReaderDeletionGenerationRace {
    var generation: UInt64 = 71
    let factoryLookup = ReaderLifetimeGate()
    private var armed = false
    private(set) var armedLookups = 0

    func arm() { armed = true }

    func libraryGeneration() async -> UInt64? {
        if armed {
            armedLookups += 1
            if armedLookups == 2 { await factoryLookup.wait() }
        }
        return generation
    }
}

@MainActor
func readerLifetimeEventually(_ predicate: @MainActor () -> Bool, milliseconds: Int = 5_000) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
    while !Task.isCancelled, !predicate(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    return !Task.isCancelled && predicate()
}

@MainActor
final class ReaderLifetimeEnvironment {
    let playback: ReadAloudPlaybackOwner
    let voice: ReaderVoiceEntry
    var readAloud: ReadAloudController?
    var tour: ReaderOnboardingTourCoordinator?
    var following = false
    var locked = false
    var revision: UInt64 = 0
    var effects: [UInt64: SharedReadingEffect] = [:]
    var request: SharedReaderNavigationRequest?

    init(fixture: ReaderDeletionFixture) {
        let state = TTSPlaybackState()
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        playback = ReadAloudPlaybackOwner(
            ttsEngine: FakeTTSEngine(state: state), ttsState: state,
            ttsSettingsStore: InMemoryTTSSettingsStore(), ttsPrewarmer: TTSPrewarmer(source: ReaderLifetimeEmptyChunks()),
            ttsPresence: TTSPresenceController(state: state, store: ReaderLifetimePresenceStore()),
            coordinator: coordinator,
            nowPlayingController: NowPlayingController(infoSurface: FakeNowPlayingInfoSurface(), commandSurface: FakeRemoteCommandSurface())
        )
        let conversations = SwiftDataConversationStore(dbStore: fixture.db)
        let messages = SwiftDataMessageStore(dbStore: fixture.db)
        let lookup = ConversationLookup(store: conversations)
        let endpoint = URL(string: "https://reader-lifetime.example.invalid")!
        let presenter = VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: WorkerClient(baseURL: endpoint, tokenProvider: StaticTokenProvider(nil)),
            baseURL: endpoint, dataUseConsentProvider: NoWorkerDataUseConsentProvider(),
            messageStore: messages, conversationLookup: lookup, userIdProvider: { fixture.owner },
            dirtyHook: NoopVoiceTranscriptDirtyHook()
        )
        voice = ReaderVoiceEntry(
            voicePresenter: presenter, conversationLookup: lookup, messageStore: messages,
            dirtyHook: NoopVoiceTranscriptDirtyHook(), chapterIndexCoordinatorFactory: { _, _ in nil },
            chapterIndexContentVersionProvider: { _ in nil }, voiceLanguageProvider: { .english }, onRequestPaywall: { _ in }
        )
    }

    private func live<Value>(_ key: ReferenceWritableKeyPath<ReaderLifetimeEnvironment, Value>) -> Binding<Value> {
        Binding(get: { self[keyPath: key] }, set: { self[keyPath: key] = $0 })
    }

    var navigation: ReaderSourceAttachment.NavigationState {
        .init(readAloud: live(\.readAloud), readerTour: live(\.tour), isFollowingController: live(\.following),
              controlsLocked: live(\.locked), navigationRevision: live(\.revision),
              navigationEffects: live(\.effects), navigationRequest: live(\.request))
    }
}

private struct ReaderLifetimeEmptyChunks: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class ReaderLifetimePresenceStore: TTSPresenceStore, @unchecked Sendable {
    func read() -> TTSPresenceSnapshot? { nil }
    func write(_ snapshot: TTSPresenceSnapshot) {}
    func clear() {}
}

@Suite("Imported book deletion drains reader lifetimes")
@MainActor
struct ImportedBookDeletionLifetimeTests {
    @Test("reader departure releases all three owners while deletion still waits for legitimate work", arguments: [false, true])
    func deleteAfterReading(visibleInvalidation: Bool) async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let environment = ReaderLifetimeEnvironment(fixture: fixture)
        let cleanup = ReaderSourceInvalidationCleanup()
        let poll = ReaderLifetimeGate()
        var lease: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
        var reader: ReaderViewModel? = fixture.makeReader(lease: try #require(lease))
        reader?.didChangeLocation(try ReaderDeletionFixture.locator())
        await reader?.flush()
        var attachment: ReaderSourceAttachment? = ReaderSourceAttachment(
            viewModel: try #require(reader), sourceLease: try #require(lease), syncEngine: fixture.sync,
            playbackOwner: environment.playback, voiceEntry: environment.voice, cleanup: cleanup,
            scopedMutationStore: BookScopedMutationStore(dbStore: fixture.db)
        )
        await attachment?.registerCleanup()
        #expect(attachment?.installIfCurrent(attachment, navigation: environment.navigation) == true)
        #expect(attachment?.isDisposed == false)
        weak var weakReader = reader
        weak var weakLease = lease
        weak var weakAttachment = attachment

        let library = fixture.makeLibrary()
        await library.refresh()
        await library.waitForHydration()
        #expect(library.books.map(\.id).contains(fixture.book.id))
        #expect(library.readingNow.contains { $0.book.id == fixture.book.id })
        #expect(library.filteredBooks.map(\.id).contains(fixture.book.id))

        // This second real managed borrower and admitted effect must still
        // prevent source drain, even after every reader-owned cycle is gone.
        var borrower: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
        var admission: SourceEffectAdmission? = try borrower?.effectAuthority.admit(try #require(borrower).sourceAccessPermit)
        defer {
            admission?.release()
            borrower = nil
            poll.open()
            attachment?.dispose()
            cleanup.dispose()
        }
        let operation = try #require(library.beginDeletion(fixture.book))
        // Confirmation updates every visible projection before completion is
        // even scheduled, while the real durable source remains borrowed.
        #expect(!library.books.contains { $0.id == fixture.book.id })
        #expect(!library.readingNow.contains { $0.book.id == fixture.book.id })
        #expect(!library.filteredBooks.contains { $0.id == fixture.book.id })
        #expect(library.positionsByBookId[fixture.book.id] == nil)
        #expect(library.coverURLs[fixture.book.id] == nil)
        var deletionCompleted = false
        let deletion = Task { await library.completeDeletion(operation); deletionCompleted = true }
        defer { deletion.cancel() }
        let invalidation = try #require(lease).owner.invalidation
        var invalidated = false
        let observation = Task {
            for await _ in invalidation.stream { invalidated = true; break }
        }
        defer { observation.cancel() }
        let didInvalidate = await readerLifetimeEventually { invalidated }
        #expect(didInvalidate)
        if visibleInvalidation, didInvalidate {
            var cleaned = false
            let action = Task { await cleanup.perform(); cleaned = true }
            let didClean = await readerLifetimeEventually { cleaned }
            if !didClean { cleanup.dispose(); attachment?.dispose() }
            #expect(didClean)
            action.cancel()
        } else {
            attachment?.dispose()
            cleanup.dispose()
        }
        attachment = nil
        reader = nil
        lease = nil
        let released = await readerLifetimeEventually { weakReader == nil && weakLease == nil && weakAttachment == nil }
        #expect(released)
        #expect(!deletionCompleted)
        // A canonical reload still sees the real row, but pending deletion
        // must remain absent through hydration and search changes.
        library.searchText = "Imported"
        var refreshCompleted = false
        let refresh = Task {
            await library.refresh()
            await library.waitForHydration()
            refreshCompleted = true
        }
        defer { refresh.cancel() }
        let didRefresh = await readerLifetimeEventually { refreshCompleted }
        #expect(didRefresh)
        #expect(!library.books.contains { $0.id == fixture.book.id })
        #expect(!library.readingNow.contains { $0.book.id == fixture.book.id })
        #expect(!library.filteredBooks.contains { $0.id == fixture.book.id })
        library.searchText = ""
        #expect(!library.filteredBooks.contains { $0.id == fixture.book.id })
        #expect(!deletionCompleted)
        #expect(try await !fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.books.book(fixture.book.id) != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(fixture.book.fileURL).path))

        admission?.release()
        admission = nil
        borrower = nil
        poll.open()
        let completed = await readerLifetimeEventually { deletionCompleted }
        if !completed { cleanup.dispose(); attachment?.dispose(); deletion.cancel() }
        observation.cancel()
        #expect(completed)
        guard completed else { return }
        #expect(library.deletionError == nil)
        #expect(try await fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.books.book(fixture.book.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(fixture.book.fileURL).path))
        #expect(!library.books.contains { $0.id == fixture.book.id })
        #expect(!library.readingNow.contains { $0.book.id == fixture.book.id })
        #expect(!library.filteredBooks.contains { $0.id == fixture.book.id })
        try await assertDeletedAfterReopen(fixture)
    }

    @Test("an unopened imported book deletes through the same persistent factory lifecycle")
    func unopenedBook() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let library = fixture.makeLibrary()
        await library.refresh()
        var completed = false
        let deletion = Task { await library.delete(fixture.book); completed = true }
        let didComplete = await readerLifetimeEventually { completed }
        if !didComplete { deletion.cancel() }
        #expect(didComplete)
        guard didComplete else { return }
        #expect(library.deletionError == nil)
        #expect(library.books.isEmpty)
        try await assertDeletedAfterReopen(fixture)
    }

    @Test("factory generation lookup cannot retire a replacement account's real managed source")
    func accountReplacementDuringFactoryLookup() async throws {
        let account = ReaderDeletionGenerationRace()
        let fixture = try await ReaderDeletionFixture.make(currentGeneration: { await account.generation })
        let library = fixture.makeLibrary(
            currentAccountGeneration: { await account.libraryGeneration() },
            currentAccountIdentity: { LibraryAccountIdentity(userID: fixture.owner, generation: account.generation) }
        )
        await library.refresh()
        await library.waitForHydration()
        #expect(library.books.contains { $0.id == fixture.book.id })
        let originalSource = try #require(try await fixture.registry.managedSource(for: fixture.book))
        let originalBytes = try Data(contentsOf: originalSource.url)
        let operation = try #require(library.beginDeletion(fixture.book))
        let readiness = library.loadReadiness
        var completed = false
        let deletion = Task {
            await library.completeDeletion(operation, closePresentedReader: { _ in account.arm() })
            completed = true
        }
        defer { account.factoryLookup.open(); deletion.cancel() }
        let reachedFactoryLookup = await readerLifetimeEventually { account.factoryLookup.entered == 1 }
        #expect(reachedFactoryLookup)
        guard reachedFactoryLookup else { return }
        #expect(account.armedLookups == 2)
        #expect(!completed)
        #expect(try await !fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)

        // Same-owner sign-in advances durable authorization while the actual
        // factory callback is suspended between VM admission and source drain.
        let replacementGeneration = fixture.generation + 1
        try await fixture.persistence.setAccountAuthorization(ownerID: fixture.owner, generation: replacementGeneration)
        account.generation = replacementGeneration
        let replacementSource = try #require(try await fixture.registry.managedSource(for: fixture.book))
        #expect(replacementSource.readingPermit.accountGeneration == replacementGeneration)
        account.factoryLookup.open()
        let didComplete = await readerLifetimeEventually { completed }
        #expect(didComplete)
        guard didComplete else { return }

        // Neither stale restoration nor error/refresh publication is allowed
        // through the old bound VM. The replacement source remains readable.
        #expect(library.deletionError == nil)
        #expect(library.books.isEmpty)
        #expect(library.readingNow.isEmpty)
        #expect(library.filteredBooks.isEmpty)
        #expect(library.positionsByBookId.isEmpty)
        #expect(library.coverURLs.isEmpty)
        #expect(library.loadReadiness == readiness)
        #expect(try await !fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(try await fixture.books.book(fixture.book.id) == fixture.book)
        #expect(try Data(contentsOf: replacementSource.url) == originalBytes)
        var replacementLease: BookSourceLease? = try await fixture.registry.acquireReadableSource(for: fixture.book)
        var admission: SourceEffectAdmission? = try replacementLease?.effectAuthority.admit(try #require(replacementLease).sourceAccessPermit)
        defer { admission?.release(); admission = nil; replacementLease = nil }
        #expect(admission != nil)

        let reopenedDB = try RishiDB.makeStore(at: fixture.databaseURL)
        let reopenedBooks = SwiftDataBookStore(dbStore: reopenedDB)
        let reopenedMetadata = try await ReaderDeletionFixture.makeMetadata(at: fixture.metadataURL)
        #expect(try await reopenedBooks.book(fixture.book.id) == fixture.book)
        #expect(try await !reopenedMetadata.isTombstone(entityId: fixture.book.id, kind: .book))
    }

    private func assertDeletedAfterReopen(_ fixture: ReaderDeletionFixture) async throws {
        let db = try RishiDB.makeStore(at: fixture.databaseURL)
        let books = SwiftDataBookStore(dbStore: db)
        let metadata = try await ReaderDeletionFixture.makeMetadata(at: fixture.metadataURL)
        #expect(try await books.book(fixture.book.id) == nil)
        #expect(try await metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        let persistence = SwiftDataBookImportPersistence(dbStore: db, managedFileRootURL: fixture.root)
        let registry = BookSourceRegistry(
            persistence: persistence, currentGeneration: { fixture.generation }, currentOwnerID: { fixture.owner },
            managedURL: { fixture.root.appendingPathComponent($0.fileURL) }
        )
        #expect(try await registry.managedSource(for: fixture.book) == nil)
        do {
            _ = try await registry.acquireReadableSource(for: fixture.book)
            Issue.record("A fresh registry reopened the deleted imported book")
        } catch { }
    }
}
