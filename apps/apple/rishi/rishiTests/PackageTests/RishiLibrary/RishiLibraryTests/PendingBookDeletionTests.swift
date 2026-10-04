@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Pending book deletion")
struct PendingBookDeletionTests {
    @Test("drains book users before tombstone and removes material only afterward")
    func drainsBeforeTombstoneAndRemoval() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Pending PDF", formatType: .pdf, fileURL: "Books/pending.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("book bytes".utf8).write(to: file)
        let order = DeletionOrder()
        let gate = AsyncDeletionGate()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = makeViewModel(
            book: book,
            store: store,
            storage: storage,
            beforeDelete: { _ in
                await order.append("drain")
                await gate.enterAndWait()
            },
            onDelete: { _ in await order.append("tombstone") },
            deleteBook: { book in
                await order.append("material")
                try await storage.delete(book)
            }
        )

        await vm.refresh()
        let deletion = Task { await vm.delete(book) }
        await gate.waitUntilEntered()
        #expect(try await store.book(book.id) == book)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await order.events == ["drain"])
        await gate.release()
        await deletion.value

        #expect(await order.events == ["drain", "tombstone", "material"])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.book(book.id) == nil)
        #expect(vm.books.isEmpty)
    }

    @Test("tombstone failure retains the book row and managed bytes")
    func tombstoneFailureRetainsBookAndMaterial() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Keep PDF", formatType: .pdf, fileURL: "Books/keep.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(book.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("book bytes".utf8).write(to: file)
        let order = DeletionOrder()
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = makeViewModel(
            book: book,
            store: store,
            storage: storage,
            beforeDelete: { _ in await order.append("drain") },
            onDelete: { _ in
                await order.append("tombstone")
                throw TestFailure.tombstoneUnavailable
            },
            restoreAfterFailure: { _, _ in
                await order.append("restore")
                return true
            },
            deleteBook: { book in
                await order.append("material")
                try await storage.delete(book)
            }
        )

        await vm.refresh()
        await vm.delete(book)

        #expect(await order.events == ["drain", "tombstone", "restore"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.book(book.id) == book)
        #expect(vm.books.map(\.id) == [book.id])
        #expect(vm.deletionError != nil)
        vm.clearDeletionError()
        #expect(vm.deletionError == nil)
    }

    @Test("failed source restoration keeps the registration fence and exposes a retry error")
    func failedRestorationKeepsFence() async throws {
        let owner = UUID()
        let book = Book(userId: owner, title: "Fenced PDF", formatType: .pdf, fileURL: "Books/fenced.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let order = DeletionOrder()
        let vm = makeViewModel(
            book: book,
            store: store,
            storage: storage,
            beforeDelete: { _ in await order.append("drain") },
            onDelete: { _ in throw TestFailure.tombstoneUnavailable },
            restoreAfterFailure: { _, _ in false },
            deleteBook: { _ in await order.append("material") }
        )
        let token = BookMaterializationToken(ownerID: owner, accountGeneration: 1, bookID: book.id, attemptID: UUID())

        await vm.refresh()
        await vm.delete(book)
        await vm.applyImportEvent(BookImportEvent(ownerID: owner, accountGeneration: 1, token: token, kind: .registered(book)))

        #expect(vm.books.map(\.id) == [book.id])
        #expect(await order.events == ["drain"])
        #expect(vm.deletionError != nil)
        #expect(try await store.book(book.id) == book)
    }

    private func makeViewModel(
        book: Book,
        store: InMemoryBookStore,
        storage: BookFileStorage,
        beforeDelete: @escaping @Sendable (Book) async throws -> Void,
        onDelete: @escaping @Sendable (BookID) async throws -> Void,
        restoreAfterFailure: @escaping @Sendable (Book, BookMaterializationToken?) async -> Bool = { _, _ in true },
        deleteBook: @escaping @Sendable (Book) async throws -> Void
    ) -> LibraryViewModel {
        LibraryViewModel(
            bookStore: store,
            currentUserId: { book.userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { book.userId }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: deleteBook,
            beforeBookDeleted: beforeDelete,
            restoreBookAfterFailedRetirement: restoreAfterFailure,
            onBookDeleted: onDelete,
            currentAccountGeneration: { 1 }
        )
    }

    private func temporaryDirectory() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("PendingBookDeletion-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor DeletionOrder {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor AsyncDeletionGate {
    private var didEnter = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum TestFailure: Error {
    case tombstoneUnavailable
}
