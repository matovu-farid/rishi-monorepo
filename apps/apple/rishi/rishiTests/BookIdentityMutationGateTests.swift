import Foundation
import SwiftData
import Testing
@testable import rishi

@MainActor
@Suite("Native book identity mutation gate", .serialized)
struct BookIdentityMutationGateTests {
    @Test("an entered live upsert completes before a queued local tombstone and cleanup")
    func liveCommitBeforeLocalTombstone() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        let barrier = IdentityMutationBarrier()
        let events = IdentityMutationEvents()
        let liveFinished = IdentityMutationCompletion()
        let deletionStarted = IdentityMutationCompletion()
        let deletionFinished = IdentityMutationCompletion()
        let live = Task {
            do {
                let result = try await fixture.metadata.withLiveBookIdentity(book.id) {
                    try await barrier.enterAndWait()
                    try await fixture.books.upsert(book)
                    await events.append("live")
                    return book.id
                }
                #expect(result == book.id)
                await liveFinished.finish()
            } catch { await liveFinished.finish(); throw error }
        }
        var deletion: Task<Void, Error>?
        do {
            try await barrier.waitUntilEntered()
            deletion = Task {
                await deletionStarted.finish()
                do {
                    try await fixture.metadata.markTombstone(entityId: book.id, kind: .book)
                    try await fixture.books.delete(book.id)
                    await events.append("deleted")
                    await deletionFinished.finish()
                } catch { await deletionFinished.finish(); throw error }
            }
            try await deletionStarted.wait()
            #expect(try await deletionFinished.remainsPending())
            #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book) == false)
            #expect(try await fixture.books.book(book.id) == nil)
            // Holding one identity does not block finite work on another book.
            let other = Book(userId: book.userId, title: "Other", formatType: .pdf, fileURL: "other.pdf")
            try await fixture.metadata.withLiveBookIdentity(other.id) { try await fixture.books.upsert(other) }
            #expect(try await fixture.books.book(other.id) == other)
            await barrier.open()
            try await liveFinished.wait()
            try await deletionFinished.wait()
            try await live.value
            try await deletion?.value
            #expect(await events.values == ["live", "deleted"])
            #expect(try await fixture.books.book(book.id) == nil)
            #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book))
            await #expect(throws: SyncMetadataError.bookIdentityClosed(book.id)) {
                try await fixture.metadata.withLiveBookIdentity(book.id) { try await fixture.books.upsert(book) }
            }
            #expect(try await fixture.books.book(book.id) == nil)
        } catch { await barrier.open(); live.cancel(); deletion?.cancel(); throw error }
    }

    @Test("incoming tombstone holds cleanup and acknowledgment together against a queued live upsert")
    func incomingCleanupBeforeLiveCommit() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        try await fixture.books.upsert(book)
        let barrier = IdentityMutationBarrier()
        let events = IdentityMutationEvents()
        let deleteFinished = IdentityMutationCompletion()
        let liveStarted = IdentityMutationCompletion()
        let liveFinished = IdentityMutationCompletion()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_031)
        let deletion = Task {
            do {
                let applied = try await fixture.metadata.applyBookTombstoneIfUnchanged(
                    book.id, expectedDirtyAt: nil, lastSyncedAt: timestamp, remoteEtag: "deleted"
                ) {
                    try await fixture.books.delete(book.id)
                    await events.append("cleanup")
                    try await barrier.enterAndWait()
                }
                #expect(applied)
                await deleteFinished.finish()
            } catch { await deleteFinished.finish(); throw error }
        }
        var live: Task<Void, Never>?
        do {
            try await barrier.waitUntilEntered()
            #expect(try await fixture.books.book(book.id) == nil)
            #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book) == false)
            live = Task {
                await liveStarted.finish()
                do {
                    await #expect(throws: SyncMetadataError.bookIdentityClosed(book.id)) {
                        try await fixture.metadata.withLiveBookIdentity(book.id) {
                            await events.append("upsert")
                            try await fixture.books.upsert(book)
                        }
                    }
                    await liveFinished.finish()
                }
            }
            try await liveStarted.wait()
            #expect(try await liveFinished.remainsPending())
            #expect(await events.values == ["cleanup"])
            await barrier.open()
            try await deleteFinished.wait()
            try await liveFinished.wait()
            try await deletion.value
            await live?.value
            #expect(await events.values == ["cleanup"])
            #expect(try await fixture.books.book(book.id) == nil)
            #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book))
            #expect(try await fixture.metadata.lastSyncedAt(entityId: book.id, kind: .book) == timestamp)
            #expect(try await fixture.metadata.pendingCount() == 0)
        } catch { await barrier.open(); deletion.cancel(); live?.cancel(); throw error }
    }

    @Test("a queued incoming tombstone waits for an entered live commit before deleting its canonical row")
    func liveCommitBeforeIncomingCleanup() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        let barrier = IdentityMutationBarrier()
        let events = IdentityMutationEvents()
        let liveFinished = IdentityMutationCompletion()
        let deleteStarted = IdentityMutationCompletion()
        let deleteFinished = IdentityMutationCompletion()
        let live = Task {
            do {
                try await fixture.metadata.withLiveBookIdentity(book.id) {
                    try await barrier.enterAndWait()
                    try await fixture.books.upsert(book)
                    await events.append("upsert")
                }
                await liveFinished.finish()
            } catch { await liveFinished.finish(); throw error }
        }
        var deletion: Task<Void, Error>?
        do {
            try await barrier.waitUntilEntered()
            deletion = Task {
                await deleteStarted.finish()
                do {
                    #expect(try await fixture.metadata.applyBookTombstoneIfUnchanged(
                        book.id, expectedDirtyAt: nil, lastSyncedAt: Date(), remoteEtag: nil
                    ) {
                        try await fixture.books.delete(book.id)
                        await events.append("cleanup")
                    })
                    await deleteFinished.finish()
                } catch { await deleteFinished.finish(); throw error }
            }
            try await deleteStarted.wait()
            #expect(try await deleteFinished.remainsPending())
            #expect(await events.values.isEmpty)
            await barrier.open()
            try await liveFinished.wait()
            try await deleteFinished.wait()
            try await live.value
            try await deletion?.value
            #expect(await events.values == ["upsert", "cleanup"])
            #expect(try await fixture.books.book(book.id) == nil)
            #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book))
        } catch { await barrier.open(); live.cancel(); deletion?.cancel(); throw error }
    }

    @Test("incoming tombstone CAS rejects changed dirtiness before invoking cleanup")
    func incomingCleanupRequiresExpectedDirtyState() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        try await fixture.books.upsert(book)
        try await fixture.metadata.markDirty(entityId: book.id, kind: .book)
        let dirtyAt = try #require(await fixture.metadata.dirtyAt(entityId: book.id, kind: .book))
        let events = IdentityMutationEvents()
        let applied = try await fixture.metadata.applyBookTombstoneIfUnchanged(
            book.id, expectedDirtyAt: dirtyAt.addingTimeInterval(-1), lastSyncedAt: Date(), remoteEtag: nil
        ) {
            await events.append("cleanup")
            try await fixture.books.delete(book.id)
        }
        #expect(!applied)
        #expect(await events.values.isEmpty)
        #expect(try await fixture.books.book(book.id) == book)
        #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book) == false)
        #expect(try await fixture.metadata.dirtyAt(entityId: book.id, kind: .book) == dirtyAt)
        // Rejection releases its gate; a valid live operation can still enter.
        #expect(try await fixture.metadata.withLiveBookIdentity(book.id) { 42 } == 42)
    }

    @Test("failed cleanup never acknowledges a tombstone and releases its gate for retry")
    func cleanupFailureDoesNotAcknowledge() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        try await fixture.books.upsert(book)
        await #expect(throws: IdentityMutationTestError.cleanupFailed) {
            try await fixture.metadata.applyBookTombstoneIfUnchanged(
                book.id, expectedDirtyAt: nil, lastSyncedAt: Date(), remoteEtag: nil
            ) { throw IdentityMutationTestError.cleanupFailed }
        }
        #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book) == false)
        #expect(try await fixture.metadata.lastSyncedAt(entityId: book.id, kind: .book) == nil)
        #expect(try await fixture.books.book(book.id) == book)
        #expect(try await fixture.metadata.withLiveBookIdentity(book.id) { 7 } == 7)
        await #expect(throws: IdentityMutationTestError.cleanupFailed) {
            try await fixture.metadata.withLiveBookIdentity(book.id) { throw IdentityMutationTestError.cleanupFailed }
        }
        #expect(try await fixture.metadata.withLiveBookIdentity(book.id) { 8 } == 8)
        #expect(try await fixture.metadata.applyBookTombstoneIfUnchanged(
            book.id, expectedDirtyAt: nil, lastSyncedAt: Date(), remoteEtag: nil
        ) { try await fixture.books.delete(book.id) })
        #expect(try await fixture.metadata.isTombstone(entityId: book.id, kind: .book))
        #expect(try await fixture.books.book(book.id) == nil)
    }

    @Test("queued cancellation removes only that waiter and cannot release an entered native commit")
    func cancelledWaiterCannotReleaseEnteredCommit() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        let barrier = IdentityMutationBarrier()
        let events = IdentityMutationEvents()
        let holderFinished = IdentityMutationCompletion()
        let canceledStarted = IdentityMutationCompletion()
        let canceledFinished = IdentityMutationCompletion()
        let successorStarted = IdentityMutationCompletion()
        let successorFinished = IdentityMutationCompletion()
        let holder = Task {
            do {
                try await fixture.metadata.withLiveBookIdentity(book.id) {
                    try await barrier.enterAndWait()
                    try await fixture.books.upsert(book)
                    await events.append("holder")
                }
                await holderFinished.finish()
            } catch { await holderFinished.finish(); throw error }
        }
        var canceled: Task<Void, Error>?
        var successor: Task<Void, Error>?
        do {
            try await barrier.waitUntilEntered()
            canceled = Task {
                await canceledStarted.finish()
                do {
                    try await fixture.metadata.withLiveBookIdentity(book.id) {
                        await events.append("canceled")
                        try await fixture.books.upsert(book)
                    }
                    await canceledFinished.finish()
                    Issue.record("canceled queued commit unexpectedly succeeded")
                } catch is CancellationError {
                    await canceledFinished.finish()
                } catch { await canceledFinished.finish(); throw error }
            }
            try await canceledStarted.wait()
            #expect(try await canceledFinished.remainsPending())
            canceled?.cancel()
            try await canceledFinished.wait()
            try await canceled?.value
            successor = Task {
                await successorStarted.finish()
                do {
                    try await fixture.metadata.withLiveBookIdentity(book.id) {
                        var newer = book
                        newer.title = "Successor"
                        try await fixture.books.upsert(newer)
                        await events.append("successor")
                    }
                    await successorFinished.finish()
                } catch { await successorFinished.finish(); throw error }
            }
            try await successorStarted.wait()
            #expect(try await successorFinished.remainsPending())
            #expect(await events.values.isEmpty)
            #expect(try await fixture.books.book(book.id) == nil)
            await barrier.open()
            try await holderFinished.wait()
            try await successorFinished.wait()
            try await holder.value
            try await successor?.value
            #expect(await events.values == ["holder", "successor"])
            #expect(try await fixture.books.book(book.id)?.title == "Successor")
            // A later tombstone must still acquire and close the same identity.
            try await fixture.metadata.markTombstone(entityId: book.id, kind: .book)
            await #expect(throws: SyncMetadataError.bookIdentityClosed(book.id)) {
                try await fixture.metadata.withLiveBookIdentity(book.id) { await events.append("after-delete") }
            }
            #expect(await events.values == ["holder", "successor"])
        } catch { await barrier.open(); holder.cancel(); canceled?.cancel(); successor?.cancel(); throw error }
    }

    @Test("account reset waits for entered native commits before clearing tombstones and metadata")
    func resetDrainsEnteredCommit() async throws {
        let fixture = try IdentityMutationFixture.make()
        let book = fixture.book
        let previouslyDeleted = UUID()
        try await fixture.metadata.markTombstone(entityId: previouslyDeleted, kind: .book)
        let barrier = IdentityMutationBarrier()
        let liveFinished = IdentityMutationCompletion()
        let resetStarted = IdentityMutationCompletion()
        let resetFinished = IdentityMutationCompletion()
        let live = Task {
            do {
                try await fixture.metadata.withLiveBookIdentity(book.id) {
                    try await barrier.enterAndWait()
                    try await fixture.books.upsert(book)
                    try await fixture.metadata.markDirty(entityId: book.id, kind: .book)
                }
                await liveFinished.finish()
            } catch { await liveFinished.finish(); throw error }
        }
        var reset: Task<Void, Error>?
        do {
            try await barrier.waitUntilEntered()
            reset = Task {
                await resetStarted.finish()
                do { try await fixture.metadata.resetAll(); await resetFinished.finish() }
                catch { await resetFinished.finish(); throw error }
            }
            try await resetStarted.wait()
            #expect(try await resetFinished.remainsPending())
            #expect(try await fixture.metadata.isTombstone(entityId: previouslyDeleted, kind: .book))
            await barrier.open()
            try await liveFinished.wait()
            try await resetFinished.wait()
            try await live.value
            try await reset?.value
            #expect(try await fixture.books.book(book.id) == book)
            #expect(try await fixture.metadata.pendingCount() == 0)
            #expect(try await fixture.metadata.dirtyAt(entityId: book.id, kind: .book) == nil)
            #expect(try await fixture.metadata.isTombstone(entityId: previouslyDeleted, kind: .book) == false)
            try await fixture.metadata.withLiveBookIdentity(previouslyDeleted) { 1 }
        } catch { await barrier.open(); live.cancel(); reset?.cancel(); throw error }
    }

    @Test("a reopened native metadata store keeps deleted identity closed while a fresh identity can commit", arguments: [false, true])
    func permanentBarrierSurvivesReopen(_ acknowledged: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("book-identity-reopen-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("sync.sqlite")
        let databaseURL = root.appendingPathComponent("books.sqlite")
        let book = Book(userId: UUID(), title: "Deleted", formatType: .pdf, fileURL: "deleted.pdf")
        // Leave live SwiftData files for OS temporary cleanup, matching the native lifetime fixtures.
        do {
            let metadata = try IdentityMutationFixture.makeMetadata(at: metadataURL)
            let books = SwiftDataBookStore(dbStore: try RishiDB.makeStore(at: databaseURL))
            try await books.upsert(book)
            try await metadata.markTombstone(entityId: book.id, kind: .book)
            if acknowledged {
                let dirtyAt = try #require(await metadata.dirtyAt(entityId: book.id, kind: .book))
                #expect(try await metadata.applyBookTombstoneIfUnchanged(
                    book.id, expectedDirtyAt: dirtyAt, lastSyncedAt: Date(), remoteEtag: "deleted"
                ) { try await books.delete(book.id) })
            } else { try await books.delete(book.id) }
            try await metadata.markDirty(entityId: book.id, kind: .book)
            try await metadata.markClean(entityId: book.id, kind: .book, lastSyncedAt: Date(), remoteEtag: "live")
            try await metadata.forget(entityId: book.id, kind: .book)
        }
        let reopened = try IdentityMutationFixture.makeMetadata(at: metadataURL)
        let books = SwiftDataBookStore(dbStore: try RishiDB.makeStore(at: databaseURL))
        #expect(try await reopened.isTombstone(entityId: book.id, kind: .book))
        #expect(try await reopened.pendingCount() == (acknowledged ? 0 : 1))
        #expect(try await books.book(book.id) == nil)
        let events = IdentityMutationEvents()
        await #expect(throws: SyncMetadataError.bookIdentityClosed(book.id)) {
            try await reopened.withLiveBookIdentity(book.id) {
                await events.append("stale-upsert")
                try await books.upsert(book)
            }
        }
        #expect(await events.values.isEmpty)
        #expect(try await books.book(book.id) == nil)
        let fresh = Book(userId: book.userId, title: "Reimported", formatType: .pdf, fileURL: "fresh.pdf")
        #expect(fresh.id != book.id)
        try await reopened.withLiveBookIdentity(fresh.id) { try await books.upsert(fresh) }
        #expect(try await books.book(fresh.id) == fresh)
        #expect(try await reopened.isTombstone(entityId: book.id, kind: .book))
    }
}

@MainActor
private struct IdentityMutationFixture {
    let metadata: SwiftDataSyncMetadataStore
    let books: SwiftDataBookStore
    let book: Book

    static func make() throws -> Self {
        Self(metadata: try SyncMetadataStoreBootstrap.makeStore(inMemory: true),
             books: SwiftDataBookStore(dbStore: try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))),
             book: Book(userId: UUID(), title: "Gated", formatType: .pdf, fileURL: "gated.pdf"))
    }

    static func makeMetadata(at url: URL) throws -> SwiftDataSyncMetadataStore {
        SwiftDataSyncMetadataStore(container: try ModelContainer(
            for: SyncMetadataRow.self, SyncCursorStateRow.self, SyncRecoveryStateRow.self,
            configurations: ModelConfiguration(url: url)
        ))
    }
}

private actor IdentityMutationBarrier {
    private var entered = false
    private var opened = false
    func enterAndWait() async throws {
        entered = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !opened {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw IdentityMutationTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !entered {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw IdentityMutationTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func open() { opened = true }
}

private actor IdentityMutationCompletion {
    private var finished = false
    func finish() { finished = true }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !finished {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw IdentityMutationTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func remainsPending() async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if finished { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return !finished
    }
}

private actor IdentityMutationEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private enum IdentityMutationTestError: Error, Equatable {
    case cleanupFailed, timedOut
}
