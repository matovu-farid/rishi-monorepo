import Foundation
import ReadiumShared
import Testing
@testable import rishi

@Suite("Reader durable position commits", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReaderPositionCommitTests {
    actor Store: PositionStore {
        var value: Position?
        var lookupFails = false
        var writeFails = false
        private(set) var writes: [Position] = []
        private struct WriteWaiter {
            let id: UUID
            let count: Int
            let continuation: CheckedContinuation<Void, Never>
        }
        private var writeWaiters: [WriteWaiter] = []
        init(_ value: Position? = nil) { self.value = value }
        func configure(lookupFails: Bool = false, writeFails: Bool = false) {
            self.lookupFails = lookupFails
            self.writeFails = writeFails
        }
        func position(for _: BookID) async throws -> Position? {
            if lookupFails { throw Failure.lookup }
            return value
        }
        func upsert(_ position: Position) async throws {
            if writeFails { throw Failure.write }
            writes.append(position)
            value = position
            let ready = writeWaiters.filter { $0.count <= writes.count }
            writeWaiters.removeAll { $0.count <= writes.count }
            ready.forEach { $0.continuation.resume() }
        }
        func waitForWrites(_ count: Int) async {
            guard writes.count < count else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { writeWaiters.append(WriteWaiter(id: id, count: count, continuation: continuation)) }
                }
            } onCancel: { Task { await self.cancelWriteWaiter(id) } }
        }
        private func cancelWriteWaiter(_ id: UUID) {
            guard let index = writeWaiters.firstIndex(where: { $0.id == id }) else { return }
            writeWaiters.remove(at: index).continuation.resume()
        }
        func delete(_: PositionID) async throws { value = nil }
    }
    enum Failure: Error { case lookup, write, publication }
    final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var entryWaiter: CheckedContinuation<Void, Never>?
        var entered = false
        func wait() async {
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitUntilEntered() async {
            guard !entered else { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { entryWaiter = continuation }
                }
            } onCancel: {
                Task { @MainActor in
                    self.entryWaiter?.resume()
                    self.entryWaiter = nil
                }
            }
        }
        func open() { waiter?.resume(); waiter = nil }
    }
    private func locator(_ progression: Double) throws -> Locator {
        Locator(href: try #require(RelativeURL(path: "chapter.xhtml")), mediaType: .xhtml,
                locations: .init(progression: progression, totalProgression: progression))
    }
    private func makeReader(_ store: Store, book: Book? = nil, debounceSeconds: Double = 60) throws -> ReaderViewModel {
        let book = book ?? Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "alice.epub")
        let url = try #require(PackageTestResourceBundle.bundle.url(forResource: "alice", withExtension: "epub"))
        return ReaderViewModel(book: book, userId: book.userId, documentURL: url, positionStore: store, debounceSeconds: debounceSeconds)
    }

    @Test("failed lookup stays failed, retry restores the effective row, absent lookup opens")
    func lookupFailureAndRetry() async throws {
        let book = Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "alice.epub")
        let saved = Position(bookId: book.id, locator: try ReaderPositionLocator(locator: locator(0.6)).encodedJSONString())
        let store = Store(saved)
        await store.configure(lookupFails: true)
        let reader = try makeReader(store, book: book)
        await reader.load()
        guard case .failed = reader.loadingState else { Issue.record("lookup failure opened reader"); return }
        #expect(reader.publication == nil)
        #expect(await reader.flush() == .committed)
        #expect(await store.writes.isEmpty)
        await store.configure()
        await reader.load()
        #expect(reader.loadingState == .loaded)
        #expect(reader.latestLocator?.locations.totalProgression == 0.6)
        reader.didChangeLocation(try locator(0.8))
        await reader.flush()
        #expect(await store.value?.id == saved.id)
        let absent = try makeReader(Store())
        await absent.load()
        #expect(absent.loadingState == .loaded)
    }

    @Test("restoration, initial viewport, programmatic reflow and unchanged flush preserve saved narration")
    func restoredProgressIsNotFreshened() async throws {
        let book = Book(userId: UUID(), title: "Alice", formatType: .epub, fileURL: "alice.epub")
        let saved = Position(bookId: book.id, locator: try ReaderPositionLocator(locator: locator(0.6), source: .readAloud).encodedJSONString(), updatedAt: Date(timeIntervalSince1970: 42))
        let store = Store(saved)
        let reader = try makeReader(store, book: book)
        await reader.load()
        reader.didChangeLocation(try locator(0.1), isInitialLocation: true)
        reader.didChangeLocation(try locator(0.2), isProgrammatic: true)
        await reader.flush()
        await reader.flush()
        #expect(await store.writes.isEmpty)
        #expect(await store.value == saved)
        #expect(reader.latestPositionSource == .readAloud)
        #expect(await reader.readAloudStartLocator()?.locations.totalProgression == 0.6)
    }

    @Test("genuine movement captures its time once, reuses one ID and unchanged callbacks do not write")
    func genuineMovementAndDedupe() async throws {
        let store = Store()
        let reader = try makeReader(store)
        let before = Date()
        reader.didChangeLocation(try locator(0.3))
        let afterEvent = Date()
        await reader.flush()
        let first = try #require(await store.value)
        #expect(first.updatedAt >= before && first.updatedAt <= afterEvent)
        reader.didChangeLocation(try locator(0.3))
        await reader.flush()
        #expect(await store.writes.count == 1)
        reader.didChangeLocation(try locator(0.5))
        await reader.flush()
        #expect(await store.value?.id == first.id)
        #expect(await store.writes.count == 2)
    }

    @Test("write failure never publishes and a later flush retries the identical snapshot")
    func writeFailureRetry() async throws {
        let store = Store()
        let reader = try makeReader(store)
        var attempts: [Position] = []
        var publications = 0
        reader.installPersistedPositionHandler(owner: UUID()) { position, persist in
            attempts.append(position)
            try await persist()
            publications += 1
            return .committed
        }
        await store.configure(writeFails: true)
        reader.didChangeLocation(try locator(0.4))
        #expect(await reader.flush() == .writeFailed)
        #expect(publications == 0)
        #expect(reader.positionSaveError != nil)
        await store.configure()
        #expect(await reader.flush() == .committed)
        #expect(publications == 1)
        #expect(attempts.count == 2)
        #expect(attempts[0] == attempts[1])
    }

    @Test("failed post-save callback retries without rewriting; engine-owned deferral completes the revision")
    func publicationRetryDoesNotRewrite() async throws {
        let store = Store()
        let reader = try makeReader(store)
        var attempts = 0
        reader.installPersistedPositionHandler(owner: UUID()) { _, persist in
            try await persist()
            attempts += 1
            if attempts == 1 { throw Failure.publication }
            return .publicationDeferred
        }
        reader.didChangeLocation(try locator(0.4))
        #expect(await reader.flush() == .savedPublicationPending)
        #expect(await reader.flush() == .savedPublicationPending)
        #expect(await store.writes.count == 1)
        #expect(attempts == 2)
        await reader.flush()
        #expect(attempts == 2)
    }

    @Test("flush drains movement arriving during publication and overlapping callers coalesce")
    func drainsConcurrentMovement() async throws {
        let store = Store()
        let reader = try makeReader(store)
        let gate = Gate()
        var publications: [Position] = []
        reader.installPersistedPositionHandler(owner: UUID()) { position, persist in
            try await persist()
            publications.append(position)
            if publications.count == 1 { await gate.wait() }
            return .committed
        }
        reader.didChangeLocation(try locator(0.2))
        let first = Task { await reader.flush() }
        while !gate.entered { await Task.yield() }
        let overlap = Task { await reader.flush() }
        reader.didChangeLocation(try locator(0.8))
        gate.open()
        #expect(await first.value == .committed)
        #expect(await overlap.value == .committed)
        #expect(publications.count == 2)
        #expect(await store.writes.count == 2)
        #expect(publications.last?.percentComplete == 0.8)
    }

    @Test("revocation prevents persistence and callback ownership protects a replacement")
    func revocationAndCallbackOwnership() async throws {
        let store = Store()
        let reader = try makeReader(store)
        let old = UUID()
        reader.installPersistedPositionHandler(owner: old) { _, _ in throw BookSourceAccessError.revoked }
        reader.didChangeLocation(try locator(0.3))
        #expect(await reader.flush() == .revoked)
        #expect(await store.writes.isEmpty)
        reader.installPersistedPositionHandler(owner: UUID()) { _, persist in try await persist(); return .committed }
        reader.clearPersistedPositionHandler(ifOwner: old)
        #expect(await reader.flush() == .committed)
        #expect(await store.writes.count == 1)
    }

    @Test("pending nil, removed and replaced owners persist the exact source snapshot without publishing to B", arguments: ["nil", "removed", "replaced"])
    func pendingSnapshotOwner(_ kind: String) async throws {
        let fixture = try await ReaderDeletionFixture.make()
        let lease = try await fixture.registry.acquireReadableSource(for: fixture.book)
        let store = Store()
        let reader = ReaderViewModel(
            book: fixture.book, userId: fixture.owner, documentURL: lease.url, positionStore: store,
            sourceLifetime: lease, sourceAccessPermit: lease.sourceAccessPermit,
            sourceEffects: lease.effectAuthority, sourceInvalidationSignal: lease.owner.invalidation,
            debounceSeconds: 60
        )
        let a = UUID(), b = UUID()
        var aCalls = 0, bCalls = 0
        if kind != "nil" {
            reader.installPersistedPositionHandler(owner: a) { _, persist in
                aCalls += 1
                try await persist()
                return .committed
            }
        }
        let movement = try locator(0.4)
        let before = Date()
        reader.didChangeReadAloudLocation(movement)
        let after = Date()
        if kind == "removed" { reader.clearPersistedPositionHandler(ifOwner: a) }
        else {
            reader.installPersistedPositionHandler(owner: b) { _, persist in
                bCalls += 1
                try await persist()
                return .committed
            }
            reader.clearPersistedPositionHandler(ifOwner: a)
        }
        #expect(await reader.flush() == .committed)
        let saved = try #require(await store.value)
        // The outer JSONEncoder does not promise key ordering. Compare the
        // entire decoded locator and explicit source rather than wire bytes.
        let decoded = try ReaderPositionLocator.decode(jsonString: saved.locator)
        #expect(decoded.source == .readAloud)
        #expect(try #require(decoded.toReadiumLocator()) == movement)
        #expect(saved.bookId == fixture.book.id)
        #expect(saved.percentComplete == movement.locations.totalProgression)
        #expect(saved.updatedAt >= before && saved.updatedAt <= after)
        #expect(aCalls == 0 && bCalls == 0)
        #expect(await store.writes.count == 1)
        // The original source remains admitted; replacement publication begins only on new movement.
        let admission = try lease.effectAuthority.admit(lease.sourceAccessPermit)
        admission.release()
        if kind == "removed" {
            reader.installPersistedPositionHandler(owner: b) { _, persist in
                bCalls += 1
                try await persist()
                return .committed
            }
        }
        reader.didChangeLocation(try locator(0.8))
        #expect(await reader.flush() == .committed)
        #expect(bCalls == 1 && aCalls == 0)
        #expect(await store.value?.id == saved.id)
    }

    @Test("debounce forwards its captured owner instead of adopting B at dispatch")
    func debounceOwner() async throws {
        let store = Store()
        let reader = try makeReader(store, debounceSeconds: 0)
        let a = UUID(), b = UUID()
        var aCalls = 0, bCalls = 0
        reader.installPersistedPositionHandler(owner: a) { _, persist in aCalls += 1; try await persist(); return .committed }
        reader.didChangeLocation(try locator(0.2))
        reader.installPersistedPositionHandler(owner: b) { _, persist in bCalls += 1; try await persist(); return .committed }
        reader.clearPersistedPositionHandler(ifOwner: a)
        // Await the actual store effect, without forcing flush or guessing timer scheduling.
        await store.waitForWrites(1)
        #expect(aCalls == 0 && bCalls == 0)
        reader.didChangeLocation(try locator(0.7))
        await store.waitForWrites(2)
        #expect(await reader.flush() == .committed)
        #expect(aCalls == 0 && bCalls == 1)
    }

    @Test("an entered A handler drains once while fresh B movement uses B")
    func admittedHandlerOwner() async throws {
        let store = Store()
        let reader = try makeReader(store)
        let gate = Gate()
        defer { gate.open() }
        let a = UUID(), b = UUID()
        var aPositions: [Position] = [], bPositions: [Position] = []
        reader.installPersistedPositionHandler(owner: a) { position, persist in
            aPositions.append(position)
            await gate.wait()
            try await persist()
            return .committed
        }
        reader.didChangeReadAloudLocation(try locator(0.2))
        let flush = Task { await reader.flush() }
        await gate.waitUntilEntered()
        reader.installPersistedPositionHandler(owner: b) { position, persist in
            bPositions.append(position)
            try await persist()
            return .committed
        }
        reader.clearPersistedPositionHandler(ifOwner: a)
        reader.didChangeLocation(try locator(0.8))
        gate.open()
        #expect(await flush.value == .committed)
        #expect(aPositions.count == 1 && bPositions.count == 1)
        #expect(aPositions.first?.percentComplete == 0.2)
        #expect(bPositions.first?.percentComplete == 0.8)
        #expect(try ReaderPositionLocator.decode(jsonString: #require(aPositions.first).locator).source == .readAloud)
        #expect(await store.writes == aPositions + bPositions)
    }

    @Test("flush does not recapture B for movement waiting behind a gated previous tail")
    func flushTailOwner() async throws {
        let store = Store()
        let reader = try makeReader(store)
        let gate = Gate()
        defer { gate.open() }
        let a = UUID(), b = UUID()
        var aCalls = 0, bCalls = 0
        reader.installPersistedPositionHandler(owner: a) { _, persist in
            aCalls += 1
            try await persist()
            await gate.wait()
            return .committed
        }
        reader.didChangeLocation(try locator(0.1))
        let flush = Task { await reader.flush() }
        await gate.waitUntilEntered()
        let before = Date()
        reader.didChangeReadAloudLocation(try locator(0.6))
        let after = Date()
        reader.installPersistedPositionHandler(owner: b) { _, persist in bCalls += 1; try await persist(); return .committed }
        gate.open()
        #expect(await flush.value == .committed)
        #expect(aCalls == 1 && bCalls == 0)
        let saved = try #require(await store.value)
        #expect(saved.percentComplete == 0.6)
        #expect(saved.updatedAt >= before && saved.updatedAt <= after)
        #expect(try ReaderPositionLocator.decode(jsonString: saved.locator).source == .readAloud)
        #expect(await store.writes.count == 2)
        reader.didChangeLocation(try locator(0.9))
        #expect(await reader.flush() == .committed)
        #expect(aCalls == 1 && bCalls == 1)
    }

    @Test("retrying an already saved A snapshot cannot publish through replacement B")
    func savedSnapshotRetryOwner() async throws {
        let store = Store()
        let reader = try makeReader(store)
        let a = UUID(), b = UUID()
        var aCalls = 0, bCalls = 0
        reader.installPersistedPositionHandler(owner: a) { _, persist in
            aCalls += 1
            try await persist()
            throw Failure.publication
        }
        reader.didChangeLocation(try locator(0.3))
        #expect(await reader.flush() == .savedPublicationPending)
        let saved = try #require(await store.value)
        reader.installPersistedPositionHandler(owner: b) { _, persist in bCalls += 1; try await persist(); return .committed }
        #expect(await reader.flush() == .committed)
        #expect(await store.value == saved)
        #expect(await store.writes.count == 1)
        #expect(aCalls == 1 && bCalls == 0)
        reader.didChangeLocation(try locator(0.5))
        #expect(await reader.flush() == .committed)
        #expect(bCalls == 1)
    }
}
