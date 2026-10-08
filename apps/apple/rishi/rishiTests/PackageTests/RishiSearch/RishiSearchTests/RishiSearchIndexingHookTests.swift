@testable import rishi
import Foundation
import os
import Testing





/// Phase 25 Plan 25-11 — verify the production indexing hook spawns a
/// detached Task that drives `IndexBuilder` through `PerBookTextExtractor`.
///
/// `.serialized` because each test spawns `Task.detached(priority: .background)`
/// for the actual indexing work; under Swift Testing's default parallel
/// execution + the cooperative thread pool sized for the host, several
/// concurrent background tasks compete for executor threads and the
/// 5-second `waitUntil` poll runs out before any builder completes. Running
/// the suite serially keeps each detached task on a hot executor.
@Suite("RishiSearchIndexingHook (25-11)", .serialized)
struct RishiSearchIndexingHookTests {

    actor ExtractionRecorder {
        private(set) var count = 0

        func record() { count += 1 }
    }

    actor CompletionRecorder {
        private(set) var completed = false

        func markCompleted() { completed = true }
    }

    private struct CountingBlockingTextExtractor: PerBookTextExtractor {
        let recorder: ExtractionRecorder
        let gate: RishiReaderLoadGate

        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] {
            await recorder.record()
            await gate.wait()
            return [(page: 1, text: "alpha")]
        }
    }

    actor RishiReaderLoadGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    // MARK: - Fixtures

    /// Stub extractor that always returns the canned paragraph rows.
    /// Optionally records each call so tests can assert routing.
    private struct StubTextExtractor: PerBookTextExtractor {
        let rows: [(page: Int, text: String)]
        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] { rows }
    }

    /// Throwing extractor used to verify the hook never crashes the import
    /// path on extraction failures.
    private struct ThrowingTextExtractor: PerBookTextExtractor {
        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] {
            throw NSError(domain: "stub", code: 1)
        }
    }

    /// Slow extractor used to verify the hook publishes an indexing status
    /// before paragraph extraction finishes.
    private struct SlowTextExtractor: PerBookTextExtractor {
        let rows: [(page: Int, text: String)]
        let delayNs: UInt64

        func extractParagraphs(
            from _: URL
        ) async throws -> [(page: Int, text: String)] {
            try await Task.sleep(nanoseconds: delayNs)
            return rows
        }
    }

    private static func makeTempRoot(_ label: String = #function) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeBook(id: UUID = UUID()) -> Book {
        Book(
            id: id,
            userId: UUID(),
            title: "Fixture",
            author: nil,
            formatType: .pdf,
            addedAt: Date(),
            openedAt: nil,
            fileURL: "Books/\(id.uuidString)/fixture.pdf",
            coverPath: nil
        )
    }

    /// Poll `predicate` up to `timeout` seconds. Used to wait on the detached
    /// indexing Task without coupling to its execution order.
    static func waitUntil(
        timeout: TimeInterval = 5.0,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000) // 25 ms
        }
        return await predicate()
    }

    // MARK: - Happy path

    @Test("scheduleIndexing returns immediately and the detached task builds the index")
    func scheduleIndexing_buildsIndexInBackground() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let extractor = StubTextExtractor(rows: [
            (page: 1, text: "alpha"),
            (page: 2, text: "beta"),
        ])
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": extractor]
        )

        // scheduleIndexing must return within a tight bound — the heavy work
        // is detached. We measure the call itself.
        let started = Date()
        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "scheduleIndexing must return without awaiting indexing work")

        // Eventually, the detached task writes the per-book files + sidecar.
        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path)
                && FileManager.default.fileExists(atPath: locator.chunksDBURL(bookId).path)
                && IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, "Detached indexing task should produce vectors.hnsw + chunks.db + .ready sidecar")
    }

    @Test("notifies chapter-index generation after the text index is ready")
    func scheduleIndexing_notifiesChapterIndexTrigger() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let trigger = ChapterTriggerRecorder()
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [(page: 1, text: "alpha")])],
            onIndexReady: { id in await trigger.record(id) }
        )

        await hook.scheduleIndexing(
            for: Self.makeBook(id: bookId),
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        let notified = await Self.waitUntil {
            await trigger.ids().contains(bookId)
        }
        #expect(notified)
    }

    @Test("scheduleIndexing marks .indexing before extraction finishes")
    func scheduleIndexing_marksIndexingBeforeExtractionCompletes() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let extractor = SlowTextExtractor(
            rows: [(page: 1, text: "alpha")],
            delayNs: 750_000_000
        )
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": extractor]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        let locator = BookIndexLocator(rootURL: root)
        let indexingVisible = await Self.waitUntil(timeout: 1.0) { @Sendable in
            if case .indexing = IndexStatusStore(url: locator.statusURL(bookId)).read() {
                return true
            }
            return false
        }
        #expect(indexingVisible, "The hook should publish .indexing before extraction completes")
    }

    @Test("concurrent calls coalesce into one in-flight extraction")
    func scheduleIndexing_coalescesConcurrentCalls() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)
        let recorder = ExtractionRecorder()
        let gate = RishiReaderLoadGate()
        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": CountingBlockingTextExtractor(recorder: recorder, gate: gate)]
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await hook.scheduleIndexing(
                    for: book,
                    fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
                )
            }
            group.addTask {
                await hook.scheduleIndexing(
                    for: book,
                    fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
                )
            }
        }

        let started = await Self.waitUntil {
            await recorder.count > 0
        }
        #expect(started)
        #expect(await recorder.count == 1)

        let completion = CompletionRecorder()
        let awaitExistingTask = Task {
            await hook.scheduleIndexingAndWait(
                for: book,
                fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
            )
            await completion.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await !completion.completed)

        await gate.open()
        await awaitExistingTask.value
        #expect(await completion.completed)
        let ready = await Self.waitUntil {
            IndexStatusStore(url: BookIndexLocator(rootURL: root).statusURL(bookId)).read() == .ready
        }
        #expect(ready)
    }

    @Test("Built index is searchable via USearchBookSearch")
    func builtIndex_endToEnd_searchable() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let embedder = IdentityEmbedder()
        let builder = IndexBuilder(rootURL: root, embedder: embedder)
        let extractor = StubTextExtractor(rows: [
            (page: 1, text: "the quick brown fox"),
            (page: 2, text: "jumps over the lazy dog"),
        ])
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": extractor]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        // Wait on the file-system sidecar so we never race the detached
        // IndexBuilder's SQLite writer with our reader opening chunks.db.
        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, "Status should reach .ready")

        // Once `.ready` is on disk the builder has finished writing — but the
        // ChunkStore actor inside the detached Task may still hold the
        // SwiftData-backed store open for a brief tear-down moment.
        // Poll the actual search path (which opens its own SwiftData store):
        // a successful open + non-empty result is the real readiness signal.
        let search = USearchBookSearch(rootURL: root, embedder: embedder, k: 3)
        var hits: [BookSearchHit] = []
        let searched = await Self.waitUntil { @Sendable in
            do {
                let result = try await search.search(
                    queryText: "the quick brown fox",
                    bookId: bookId
                )
                if !result.isEmpty {
                    return true
                }
                return false
            } catch {
                return false
            }
        }
        if searched {
            hits = (try? await search.search(
                queryText: "the quick brown fox",
                bookId: bookId
            )) ?? []
        }
        #expect(searched, "Search must eventually succeed once chunks.db is releasable")
        #expect(!hits.isEmpty, "Searching the index should return at least one hit")
    }

    // MARK: - Routing + edge cases

    @Test("Unknown extension logs no_extractor and writes no index files")
    func unknownExtension_logsAndSkips() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [(1, "ignored")])]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.unknown")
        )

        // Give any (incorrectly) spawned detached task a moment to land.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let locator = BookIndexLocator(rootURL: root)
        #expect(
            !FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path),
            "Unknown extension must NOT trigger an index build"
        )
        #expect(
            !FileManager.default.fileExists(atPath: locator.chunksDBURL(bookId).path),
            "Unknown extension must NOT touch chunks.db"
        )
    }

    @Test("Routing keys are matched case-insensitively via lowercased extension")
    func routingIsCaseInsensitive() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let extractor = StubTextExtractor(rows: [(page: 1, text: "alpha")])
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["epub": extractor]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/Book.EPUB")
        )

        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, ".EPUB upper-case extension should resolve via lowercased lookup")
    }

    @Test("Extractor throwing does not propagate; status becomes .failed")
    func extractorThrow_endsAsFailedSidecar() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": ThrowingTextExtractor()]
        )

        // Must not throw out of scheduleIndexing even though the extractor
        // (inside the detached Task) throws.
        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        // The hook catches the throw inside the detached Task and must move
        // the status sidecar out of `.notIndexed` to `.failed` — otherwise
        // `BookSearchStatus.shouldBackfillIndex` stays true and every
        // reader-open re-schedules indexing (thrash). `.failed` is terminal:
        // no backfill, and the chip stops polling.
        let locator = BookIndexLocator(rootURL: root)
        let failed = await Self.waitUntil { @Sendable in
            if case .failed = IndexStatusStore(url: locator.statusURL(bookId)).read() {
                return true
            }
            return false
        }
        #expect(failed, "Extractor throw should leave status .failed, not stuck at .notIndexed")
        #expect(
            !FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path),
            "Extractor throw must not produce a vectors.hnsw file"
        )
    }

    @Test("Unknown extension writes a .failed sidecar so status leaves .notIndexed")
    func unknownExtension_endsAsFailedSidecar() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [(1, "ignored")])]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.unknown")
        )

        // No registered extractor — the hook must still mark the sidecar
        // `.failed` so `shouldBackfillIndex` skips it and the reader does not
        // re-schedule indexing on every open.
        let locator = BookIndexLocator(rootURL: root)
        let failed = await Self.waitUntil { @Sendable in
            if case .failed = IndexStatusStore(url: locator.statusURL(bookId)).read() {
                return true
            }
            return false
        }
        #expect(failed, "Unknown extension should leave status .failed, not stuck at .notIndexed")
        #expect(
            !FileManager.default.fileExists(atPath: locator.vectorsURL(bookId).path),
            "Unknown extension must NOT trigger an index build"
        )
    }

    @Test("Empty paragraphs produce a .ready sidecar without crashing")
    func emptyParagraphs_completesReady() async throws {
        let root = Self.makeTempRoot()
        let bookId = UUID()
        let book = Self.makeBook(id: bookId)

        let builder = IndexBuilder(rootURL: root, embedder: IdentityEmbedder())
        let hook = RishiSearchIndexingHook(
            builder: builder,
            extractors: ["pdf": StubTextExtractor(rows: [])]
        )

        await hook.scheduleIndexing(
            for: book,
            fileURL: URL(fileURLWithPath: "/tmp/fixture.pdf")
        )

        let locator = BookIndexLocator(rootURL: root)
        let ready = await Self.waitUntil { @Sendable in
            IndexStatusStore(url: locator.statusURL(bookId)).read() == .ready
        }
        #expect(ready, "Empty paragraphs should still produce a .ready sidecar")
    }
    @Test("real lifecycle cancels indexing but deletion waits for the entered source read")
    @MainActor
    func deletionCancelsActualIndexingAndDrainsEnteredRead() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let registry = fixture.registry
        let owner = fixture.owner
        let generation = fixture.generation
        let managedURL = fixture.root.appendingPathComponent(fixture.book.fileURL)
        let recorder = ExtractionRecorder()
        let gate = RishiReaderLoadGate()
        let completion = ChapterTriggerRecorder()
        let hook = RishiSearchIndexingHook(
            builder: IndexBuilder(rootURL: fixture.root, embedder: IdentityEmbedder()),
            extractors: ["epub": CountingBlockingTextExtractor(recorder: recorder, gate: gate)],
            onIndexReady: { id in await completion.record(id) },
            acquireSource: { book in
                BookIndexingSource(identity: .init(ownerID: owner, generation: generation, bookID: book.id),
                                   lease: try await registry.acquireReadableSource(for: book))
            }
        )
        let lifecycle = BookImportLifecycle(
            sourceRegistry: registry, currentAccountGeneration: { generation },
            cancelOwnerWork: { hook.cancelOwner(ownerID: $0, generation: $1) },
            drainOwnerWork: { await hook.drainOwner(ownerID: $0, generation: $1) },
            cancelBookWork: { hook.cancelBook(ownerID: $0, generation: $1, bookID: $2) },
            drainBookWork: { await hook.drainBook(ownerID: $0, generation: $1, bookID: $2) }
        )
        let identity = LibraryAccountIdentity(userID: owner, generation: generation)
        let sync = fixture.sync
        let library = LibraryViewModel.make(
            bookStore: fixture.books, userId: owner,
            importCoordinator: ImportCoordinator(storage: fixture.storage, currentUserId: { owner }),
            positionStore: fixture.positions, bookFileStorage: fixture.storage, bookSourceRegistry: registry,
            bookImportLifecycle: lifecycle, currentAccountGeneration: { generation },
            accountIdentity: identity, currentAccountIdentity: { identity },
            onBookDeleted: { try await sync.markBookDeleted($0) }
        )
        await hook.scheduleIndexing(for: fixture.book, fileURL: managedURL)
        #expect(await Self.waitUntil { await recorder.count == 1 })
        let done = CompletionRecorder()
        let deletion = Task { await library.delete(fixture.book); await done.markCompleted() }
        #expect(await Self.waitUntil {
            lifecycle.isBookRetiredForDeletion(ownerID: owner, generation: generation, bookID: fixture.book.id)
        })
        #expect(await !done.completed)
        #expect(try await fixture.books.book(fixture.book.id) != nil)
        #expect(try await fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book) == false)
        #expect(FileManager.default.fileExists(atPath: managedURL.path))
        // Neither another importer nor a reader waiter can start replacement
        // work through the now-retired source while the original read unwinds.
        await hook.scheduleIndexing(for: fixture.book, fileURL: managedURL)
        #expect(await recorder.count == 1)
        await gate.open()
        let finished = await Self.waitUntil { await done.completed }
        #expect(finished)
        if !finished { deletion.cancel() }
        if finished { await deletion.value }
        #expect(await completion.ids().isEmpty)
        #expect(try await fixture.books.book(fixture.book.id) == nil)
        #expect(try await fixture.metadata.isTombstone(entityId: fixture.book.id, kind: .book))
        #expect(!FileManager.default.fileExists(atPath: BookIndexLocator(rootURL: fixture.root).bookDir(fixture.book.id).path))
        let reopened = try RishiDB.makeStore(at: fixture.databaseURL)
        #expect(try await SwiftDataBookStore(dbStore: reopened).book(fixture.book.id) == nil)
        let reopenedMetadata = try await ReaderDeletionFixture.makeMetadata(at: fixture.metadataURL)
        #expect(try await reopenedMetadata.isTombstone(entityId: fixture.book.id, kind: .book))
    }

    @Test("retirement rejects a source acquired before task insertion without sidecar writes")
    @MainActor
    func retirementClosesProviderInsertionRace() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let registry = fixture.registry
        let owner = fixture.owner
        let generation = fixture.generation
        let ready = CompletionRecorder()
        let providerGate = RishiReaderLoadGate()
        let recorder = ExtractionRecorder()
        let hook = RishiSearchIndexingHook(
            builder: IndexBuilder(rootURL: fixture.root, embedder: IdentityEmbedder()),
            extractors: ["epub": CountingBlockingTextExtractor(recorder: recorder, gate: RishiReaderLoadGate())],
            acquireSource: { book in
                let lease = try await registry.acquireReadableSource(for: book)
                await ready.markCompleted()
                await providerGate.wait()
                return BookIndexingSource(identity: .init(ownerID: owner, generation: generation, bookID: book.id), lease: lease)
            }
        )
        let scheduled = CompletionRecorder()
        let start = Task {
            await hook.scheduleIndexing(for: fixture.book, fileURL: fixture.root.appendingPathComponent(fixture.book.fileURL))
            await scheduled.markCompleted()
        }
        #expect(await Self.waitUntil { await ready.completed })
        registry.fenceBookSynchronously(ownerID: owner, generation: generation, bookID: fixture.book.id)
        hook.cancelBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
        await providerGate.open()
        #expect(await Self.waitUntil { await scheduled.completed })
        await start.value
        #expect(await recorder.count == 0)
        #expect(!FileManager.default.fileExists(atPath: BookIndexLocator(rootURL: fixture.root).statusURL(fixture.book.id).path))
        await hook.drainBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
    }

    @Test("authorized rollback admits a fresh source after the canceled writer actually finishes")
    @MainActor
    func authorizedRollbackIndexesThroughFreshSource() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let registry = fixture.registry
        let owner = fixture.owner
        let generation = fixture.generation
        let recorder = ExtractionRecorder()
        let gate = RishiReaderLoadGate()
        let hook = RishiSearchIndexingHook(
            builder: IndexBuilder(rootURL: fixture.root, embedder: IdentityEmbedder()),
            extractors: ["epub": CountingBlockingTextExtractor(recorder: recorder, gate: gate)],
            acquireSource: { book in
                BookIndexingSource(identity: .init(ownerID: owner, generation: generation, bookID: book.id),
                                   lease: try await registry.acquireReadableSource(for: book))
            }
        )
        let url = fixture.root.appendingPathComponent(fixture.book.fileURL)
        await hook.scheduleIndexing(for: fixture.book, fileURL: url)
        #expect(await Self.waitUntil { await recorder.count == 1 })
        registry.fenceBookSynchronously(ownerID: owner, generation: generation, bookID: fixture.book.id)
        hook.cancelBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
        await gate.open()
        await hook.drainBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
        await registry.retireSource(ownerID: owner, generation: generation, bookID: fixture.book.id)
        await registry.drainBook(ownerID: owner, generation: generation, bookID: fixture.book.id)
        #expect(registry.activateBookSynchronously(ownerID: owner, generation: generation, bookID: fixture.book.id))
        await hook.scheduleIndexingAndWait(for: fixture.book, fileURL: url)
        #expect(await recorder.count == 2)
        #expect(IndexStatusStore(url: BookIndexLocator(rootURL: fixture.root).statusURL(fixture.book.id)).read() == .ready)
    }

    private actor GenerationValue {
        var value: UInt64 = 71
        func replace(_ value: UInt64) { self.value = value }
    }

    @Test("old-generation cancellation and completion leave a replacement-generation writer usable")
    @MainActor
    func cancelledGenerationCannotStopReplacementWriter() async throws {
        let generations = GenerationValue()
        let fixture = try await ReaderDeletionFixture.make(currentGeneration: { await generations.value })
        let registry = fixture.registry
        let owner = fixture.owner
        let firstGeneration = fixture.generation
        let gate = RishiReaderLoadGate()
        let recorder = ExtractionRecorder()
        let completion = ChapterTriggerRecorder()
        let hook = RishiSearchIndexingHook(
            builder: IndexBuilder(rootURL: fixture.root, embedder: IdentityEmbedder()),
            extractors: ["epub": CountingBlockingTextExtractor(recorder: recorder, gate: gate)],
            onIndexReady: { id in await completion.record(id) },
            acquireSource: { book in
                let lease = try await registry.acquireReadableSource(for: book)
                guard case let .account(permit) = lease.access else { throw CancellationError() }
                return BookIndexingSource(identity: .init(ownerID: owner, generation: permit.accountGeneration, bookID: book.id), lease: lease)
            }
        )
        let url = fixture.root.appendingPathComponent(fixture.book.fileURL)
        await hook.scheduleIndexing(for: fixture.book, fileURL: url)
        #expect(await Self.waitUntil { await recorder.count == 1 })
        registry.fenceBookSynchronously(ownerID: owner, generation: firstGeneration, bookID: fixture.book.id)
        hook.cancelBook(ownerID: owner, generation: firstGeneration, bookID: fixture.book.id)
        let nextGeneration = firstGeneration + 1
        await generations.replace(nextGeneration)
        let fingerprint = try #require(try await fixture.persistence.fingerprint(bookID: fixture.book.id, ownerID: owner))
        try await fixture.persistence.setAccountAuthorization(ownerID: owner, generation: nextGeneration)
        try await fixture.persistence.setBookReadingAuthorization(
            bookID: fixture.book.id, ownerID: owner, generation: nextGeneration,
            contentRevision: fingerprint.version.materializationRevision, tombstoned: false
        )
        let replacementCompleted = CompletionRecorder()
        let replacement = Task {
            await hook.scheduleIndexingAndWait(for: fixture.book, fileURL: url)
            await replacementCompleted.markCompleted()
        }
        #expect(await Self.waitUntil { await recorder.count == 2 })
        hook.cancelOwner(ownerID: owner, generation: firstGeneration)
        #expect(await !replacementCompleted.completed)
        await gate.open()
        #expect(await Self.waitUntil { await replacementCompleted.completed })
        await replacement.value
        await hook.drainOwner(ownerID: owner, generation: firstGeneration)
        #expect(await completion.ids() == [fixture.book.id])
        #expect(IndexStatusStore(url: BookIndexLocator(rootURL: fixture.root).statusURL(fixture.book.id)).read() == .ready)
        let readable = try await registry.acquireReadableSource(for: fixture.book)
        guard case let .account(permit) = readable.access else { Issue.record("Replacement source lost account authority"); return }
        #expect(permit.accountGeneration == nextGeneration)
    }

    @Test("EPUB extraction propagates cancellation instead of accepting an empty book")
    @MainActor
    func epubCancellationIsNotSwallowed() async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let gate = RishiReaderLoadGate()
        let task = Task {
            await gate.wait()
            return try await EpubTextExtractor().extractParagraphs(from: fixture.root.appendingPathComponent(fixture.book.fileURL))
        }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}

private actor ChapterTriggerRecorder {
    private var recorded: [UUID] = []
    func record(_ id: UUID) { recorded.append(id) }
    func ids() -> [UUID] { recorded }
}
