@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Library import publication")
struct LibraryImportPublicationTests {
    @Test("base books publish before position and cover hydration completes")
    func publishesBaseBeforeHydration() async throws {
        let userID = UUID()
        let coverGate = AsyncGate()
        let positionGate = AsyncGate()
        let coverURL = URL(fileURLWithPath: "/tmp/cover.heic")
        let book = Book(userId: userID, title: "Quick Import", formatType: .pdf, fileURL: "Books/book.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { userID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userID }),
            positionLoader: PositionLoader(positionStore: BlockingPositionStore(gate: positionGate, percent: 0.4)),
            coverResolver: BookCoverResolver(resolve: { _ in
                await coverGate.pause()
                return coverURL
            }),
            deleteBook: { _ in }
        )

        await vm.refresh()
        #expect(vm.books.map(\.id) == [book.id])
        #expect(vm.filteredBooks.map(\.id) == [book.id])
        #expect(vm.position(for: book.id) == nil)
        #expect(vm.coverURLs[book.id] == nil)

        await positionGate.waitUntilPaused()
        await coverGate.waitUntilPaused()
        await positionGate.open()
        await coverGate.open()
        await vm.waitForHydration()

        #expect(vm.position(for: book.id)?.percentComplete == 0.4)
        #expect(vm.readingNow.map(\.book.id) == [book.id])
        #expect(vm.coverURLs[book.id] == coverURL)
    }

    @Test("completed hydration clears positions and covers removed from its snapshot")
    func completedHydrationClearsRemovedValues() async throws {
        let userID = UUID()
        let book = Book(userId: userID, title: "Cleared Metadata", formatType: .pdf, fileURL: "Books/book.pdf")
        let savedPosition = Position(bookId: book.id, locator: "position", percentComplete: 0.4)
        let positionStore = ControlledPositionStore(position: savedPosition)
        let coverProbe = ControlledCoverProbe(url: URL(fileURLWithPath: "/tmp/saved-cover.heic"))
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { userID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userID }),
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(resolve: { _ in await coverProbe.resolve() }),
            deleteBook: { _ in }
        )

        await vm.refresh()
        await vm.waitForHydration()
        #expect(vm.position(for: book.id) == savedPosition)
        #expect(vm.coverURLs[book.id] == URL(fileURLWithPath: "/tmp/saved-cover.heic"))

        let positionGate = AsyncGate()
        let coverGate = AsyncGate()
        await positionStore.configure(position: nil, gate: positionGate)
        await coverProbe.configure(url: nil, gate: coverGate)
        await vm.refresh()

        // Existing values stay visible until this refresh's resolver results arrive.
        #expect(vm.position(for: book.id) == savedPosition)
        #expect(vm.coverURLs[book.id] == URL(fileURLWithPath: "/tmp/saved-cover.heic"))
        await positionGate.waitUntilPaused()
        await coverGate.waitUntilPaused()
        await positionGate.open()
        await coverGate.open()
        await vm.waitForHydration()

        #expect(vm.position(for: book.id) == nil)
        #expect(vm.readingNow.isEmpty)
        #expect(vm.coverURLs[book.id] == nil)
    }

    @Test("late hydration cannot restore a book deleted after base publication")
    func deletedBookIsNotRestoredByHydration() async throws {
        let userID = UUID()
        let gate = AsyncGate()
        let book = Book(userId: userID, title: "Delete During Load", formatType: .pdf, fileURL: "Books/book.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { userID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userID }),
            positionLoader: PositionLoader(positionStore: BlockingPositionStore(gate: gate, percent: 0.5)),
            coverResolver: BookCoverResolver(resolve: { _ in nil }),
            deleteBook: { try await store.delete($0.id) }
        )

        await vm.refresh()
        await gate.waitUntilPaused()
        await vm.delete(book)
        await gate.open()
        await vm.waitForHydration()

        #expect(vm.books.isEmpty)
        #expect(vm.readingNow.isEmpty)
        #expect(vm.position(for: book.id) == nil)
    }

    @Test("same-ID account switches clear retained position and cover state")
    func accountSwitchClearsRetainedValuesForReusedBookID() async throws {
        let firstOwner = UUID()
        let secondOwner = UUID()
        var currentOwner: UserID? = firstOwner
        let bookID = UUID()
        let oldBook = Book(id: bookID, userId: firstOwner, title: "Previous Account", formatType: .pdf, fileURL: "Books/book.pdf")
        let oldPosition = Position(bookId: bookID, locator: "old-position", percentComplete: 0.5)
        let positionStore = ControlledPositionStore(position: oldPosition)
        let coverProbe = ControlledCoverProbe(url: URL(fileURLWithPath: "/tmp/previous-owner.heic"))
        let store = InMemoryBookStore(initial: [oldBook])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { currentOwner },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { firstOwner }),
            positionLoader: PositionLoader(positionStore: positionStore),
            coverResolver: BookCoverResolver(resolve: { _ in await coverProbe.resolve() }),
            deleteBook: { _ in }
        )

        await vm.refresh()
        await vm.waitForHydration()
        #expect(vm.position(for: bookID) == oldPosition)
        #expect(vm.coverURLs[bookID] == URL(fileURLWithPath: "/tmp/previous-owner.heic"))

        var newBook = oldBook
        newBook.userId = secondOwner
        newBook.title = "Next Account"
        try await store.upsert(newBook)
        let positionGate = AsyncGate()
        let coverGate = AsyncGate()
        await positionStore.configure(position: nil, gate: positionGate)
        await coverProbe.configure(url: nil, gate: coverGate)
        currentOwner = secondOwner
        await vm.refresh()
        #expect(vm.books.map(\.id) == [bookID])
        #expect(vm.position(for: bookID) == nil)
        #expect(vm.coverURLs[bookID] == nil)
        await positionGate.waitUntilPaused()
        await coverGate.waitUntilPaused()
        await positionGate.open()
        await coverGate.open()
        await vm.waitForHydration()

        #expect(vm.books.first?.userId == secondOwner)
        #expect(vm.position(for: bookID) == nil)
        #expect(vm.coverURLs[bookID] == nil)
    }

    @Test("late cover hydration cannot replace a newer book publication")
    func newerBookSnapshotWinsOverLateCover() async throws {
        let userID = UUID()
        let oldCoverGate = AsyncGate()
        let oldCover = URL(fileURLWithPath: "/tmp/old-cover.heic")
        let newCover = URL(fileURLWithPath: "/tmp/new-cover.heic")
        let book = Book(userId: userID, title: "Before", formatType: .pdf, fileURL: "Books/book.pdf")
        let store = InMemoryBookStore(initial: [book])
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BookFileStorage(rootURL: root, bookStore: store, coverExtractors: [:])
        let vm = LibraryViewModel(
            bookStore: store,
            currentUserId: { userID },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userID }),
            positionLoader: PositionLoader(positionStore: InMemoryPositionStore()),
            coverResolver: BookCoverResolver(resolve: { book in
                if book.title == "Before" {
                    await oldCoverGate.pause()
                    return oldCover
                }
                return newCover
            }),
            deleteBook: { _ in }
        )

        await vm.refresh()
        await oldCoverGate.waitUntilPaused()
        var updatedBook = book
        updatedBook.title = "After"
        try await store.upsert(updatedBook)
        await vm.refresh()
        await vm.waitForHydration()
        await oldCoverGate.open()

        #expect(vm.books.first?.title == "After")
        #expect(vm.coverURLs[book.id] == newCover)
    }

    private func temporaryDirectory() -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("LibraryPublication-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor AsyncGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            release = continuation
        }
    }

    func waitUntilPaused() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

private actor BlockingPositionStore: PositionStore {
    private let gate: AsyncGate
    private let percent: Double

    init(gate: AsyncGate, percent: Double) {
        self.gate = gate
        self.percent = percent
    }

    func position(for bookId: BookID) async throws -> Position? {
        await gate.pause()
        return Position(bookId: bookId, locator: "position", percentComplete: percent)
    }

    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

private actor ControlledPositionStore: PositionStore {
    private var value: Position?
    private var gate: AsyncGate?

    init(position: Position?) {
        self.value = position
    }

    func configure(position: Position?, gate: AsyncGate?) {
        self.value = position
        self.gate = gate
    }

    func position(for bookId: BookID) async throws -> Position? {
        let resolvedPosition = self.value?.bookId == bookId ? self.value : nil
        let resolverGate = gate
        if let resolverGate { await resolverGate.pause() }
        return resolvedPosition
    }

    func upsert(_ position: Position) async throws { value = position }
    func delete(_ id: PositionID) async throws {
        if value?.id == id { value = nil }
    }
}

private actor ControlledCoverProbe {
    private var url: URL?
    private var gate: AsyncGate?

    init(url: URL?) {
        self.url = url
    }

    func configure(url: URL?, gate: AsyncGate?) {
        self.url = url
        self.gate = gate
    }

    func resolve() async -> URL? {
        let resolvedURL = url
        let resolverGate = gate
        if let resolverGate { await resolverGate.pause() }
        return resolvedURL
    }
}
