@testable import rishi
import Foundation
import Testing




@Suite("ImportCoordinator")
struct ImportCoordinatorTests {

    private actor ImportedBookRecorder {
        var ids: [BookID] = []

        func append(_ id: BookID) {
            ids.append(id)
        }
    }

    private actor BlockingImportStorage: BookImportingStorage {
        private let book: Book
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var importCount = 0

        init(book: Book) { self.book = book }

        func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?) async throws -> Book {
            importCount += 1
            started = true
            let pending = startWaiters
            startWaiters.removeAll()
            pending.forEach { $0.resume() }
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            return book
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            let pending = releaseWaiters
            releaseWaiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor GenerationRecordingStorage: BookImportingStorage {
        private let book: Book
        private(set) var receivedGeneration: UInt64?

        init(book: Book) { self.book = book }

        func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?) async throws -> Book { book }

        func importBook(from sourceURL: URL, ownerId: UserID, expectedContentHash: String?, accountGeneration: UInt64) async throws -> Book {
            receivedGeneration = accountGeneration
            return book
        }
    }

    private actor DrainCompletion {
        private var completed = false
        func mark() { completed = true }
        func value() -> Bool { completed }
    }

    static func makeRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImportCoordinator-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("filterSupported keeps only known extensions (case-insensitive)")
    func filtersExtensions() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.EPUB"),
            URL(fileURLWithPath: "/tmp/c.mobi"),
            URL(fileURLWithPath: "/tmp/d.azw3"),
            URL(fileURLWithPath: "/tmp/e.txt"),
            URL(fileURLWithPath: "/tmp/f"),
        ]
        let kept = ImportCoordinator.filterSupported(urls).map { $0.lastPathComponent }
        #expect(kept == ["a.pdf", "b.EPUB", "c.mobi", "d.azw3"])
    }

    @Test("importBooks forwards each supported URL to BookFileStorage")
    func forwardsToStorage() async throws {
        let root = Self.makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let userId = UUID()
        let coordinator = ImportCoordinator(storage: storage) { userId }

        let a = root.appendingPathComponent("a.pdf")
        try Data([0]).write(to: a)
        let b = root.appendingPathComponent("b.txt")
        try Data([0]).write(to: b)

        let outcomes = await coordinator.importBooks([a, b])
        // 'b.txt' filtered out → only one outcome.
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.book != nil)
        #expect(outcomes.first?.error == nil)

        let stored = try await store.books(for: userId)
        #expect(stored.count == 1)
    }

    @Test("successful imports invoke the normal outbound-sync hook")
    func successfulImportInvokesSyncHook() async throws {
        let root = Self.makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let userId = UUID()
        let recorder = ImportedBookRecorder()
        let coordinator = ImportCoordinator(
            storage: storage,
            currentUserId: { userId },
            onBookImported: { id in await recorder.append(id) }
        )

        let source = root.appendingPathComponent("sync-hook.pdf")
        try Data([0]).write(to: source)
        let outcomes = await coordinator.importBooks([source])
        guard let importedID = outcomes.first?.book?.id else {
            Issue.record("expected the fixture book to be imported")
            return
        }

        #expect(await recorder.ids == [importedID])
    }

    @Test("account drain waits for a picker copy and rejects later imports")
    func accountFenceWaitsForPickerImport() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Blocked", formatType: .pdf, fileURL: "Books/blocked.pdf")
        let storage = BlockingImportStorage(book: book)
        let registry = BookSourceRegistry(currentGeneration: { 31 }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { 31 })
        let root = Self.makeRoot()
        let source = root.appendingPathComponent("blocked.pdf")
        try Data("selected source".utf8).write(to: source)
        let coordinator = ImportCoordinator(
            storage: storage,
            currentUserId: { userID },
            lifecycle: lifecycle
        )

        let importTask = Task { await coordinator.importBooks([source]) }
        await storage.waitUntilStarted()
        lifecycle.fenceAccount(ownerID: userID, generation: 31)
        let drained = DrainCompletion()
        let drainTask = Task {
            await lifecycle.drainAccount(userID, generation: 31)
            await drained.mark()
        }
        await Task.yield()
        #expect(await !drained.value())
        #expect(lifecycle.admitOwnerOperation(ownerID: userID, generation: 31) == nil)
        #expect(lifecycle.admitOwnerOperation(ownerID: userID, generation: 32) == nil)

        let rejected = await coordinator.importBooks([source])
        #expect(rejected.first?.error == "account_revoked")
        #expect(await storage.importCount == 1)

        await storage.release()
        #expect((await importTask.value).first?.book?.id == book.id)
        await drainTask.value
        #expect(await drained.value())
    }

    @Test("picker storage receives the generation admitted before import starts")
    func forwardsCapturedGeneration() async throws {
        let userID = UUID()
        let generation: UInt64 = 41
        let book = Book(userId: userID, title: "Captured", formatType: .pdf, fileURL: "Books/captured.pdf")
        let storage = GenerationRecordingStorage(book: book)
        let registry = BookSourceRegistry(currentGeneration: { generation }, currentOwnerID: { userID }, managedURL: { _ in nil })
        let lifecycle = BookImportLifecycle(sourceRegistry: registry, currentAccountGeneration: { generation })
        let coordinator = ImportCoordinator(storage: storage, currentUserId: { userID }, lifecycle: lifecycle)
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("captured.pdf")
        try Data("selected".utf8).write(to: source)

        let outcomes = await coordinator.importBooks([source])

        #expect(outcomes.first?.book?.id == book.id)
        #expect(await storage.receivedGeneration == generation)
    }

    @Test("Missing user yields outcomes flagged 'no_user' with no DB writes")
    func noUserShortCircuits() async throws {
        let root = Self.makeRoot()
        let store = InMemoryBookStore()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let coordinator = ImportCoordinator(storage: storage) { nil }

        let a = root.appendingPathComponent("a.pdf")
        try Data([0]).write(to: a)

        let outcomes = await coordinator.importBooks([a])
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.error == "no_user")
        #expect(outcomes.first?.book == nil)

        // No book row inserted.
        let snapshot = await store.snapshot()
        #expect(snapshot.isEmpty)
    }

    @Test("allowedExtensions matches BookFormat.allCases raw values")
    func allowListMatchesBookFormat() {
        let formatExts = Set(BookFormat.allCases.map { $0.rawValue.lowercased() })
        #expect(ImportCoordinator.allowedExtensions == formatExts)
    }
}
