import Testing
import Foundation
@testable import RishiLibrary
import RishiCore
import RishiTesting

@MainActor
@Suite("LibraryViewModel")
struct LibraryViewModelTests {

    static func setup() async -> (LibraryViewModel, InMemoryBookStore, InMemoryPositionStore, UserID, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VM-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookStore = InMemoryBookStore()
        let positionStore = InMemoryPositionStore()
        let storage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let userId = UUID()
        let vm = LibraryViewModel(bookStore: bookStore, positionStore: positionStore,
                                  storage: storage, currentUserId: { userId },
                                  importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId }))
        return (vm, bookStore, positionStore, userId, root)
    }

    @Test("refresh populates books + readingNow filters to in-progress positions only")
    func refreshHappyPath() async throws {
        let (vm, bookStore, positionStore, userId, _) = await Self.setup()
        let a = Book(userId: userId, title: "A", formatType: .pdf, fileURL: "a")
        let b = Book(userId: userId, title: "B", formatType: .pdf, fileURL: "b")
        let c = Book(userId: userId, title: "C", formatType: .pdf, fileURL: "c")
        try await bookStore.upsert(a); try await bookStore.upsert(b); try await bookStore.upsert(c)
        // a is in-progress (0.5), b is just-started (0.0 → NOT readingNow),
        // c is finished (1.0 → NOT readingNow).
        try await positionStore.upsert(Position(bookId: a.id, locator: "page:1", percentComplete: 0.5))
        try await positionStore.upsert(Position(bookId: b.id, locator: "page:1", percentComplete: 0.0))
        try await positionStore.upsert(Position(bookId: c.id, locator: "page:1", percentComplete: 1.0))

        await vm.refresh()
        #expect(vm.books.count == 3)
        #expect(vm.readingNow.map(\.book.title) == ["A"])
    }

    @Test("readingNow caps at 3, keeping the most recently read")
    func readingNowCapsAtThree() async throws {
        let (vm, bookStore, positionStore, userId, _) = await Self.setup()
        let now = Date()
        // Five in-progress books, each read at a distinct time.
        for i in 0..<5 {
            let book = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "b\(i)")
            try await bookStore.upsert(book)
            try await positionStore.upsert(Position(bookId: book.id,
                                                    locator: "page:1",
                                                    percentComplete: 0.5,
                                                    updatedAt: now.addingTimeInterval(Double(i))))
        }
        await vm.refresh()
        // B4..B2 are the three most-recently updated.
        #expect(vm.readingNow.map(\.book.title) == ["B4", "B3", "B2"])
    }

    @Test("delete removes from books + readingNow + filteredBooks")
    func deleteCascades() async throws {
        let (vm, bookStore, positionStore, userId, _) = await Self.setup()
        let a = Book(userId: userId, title: "A", formatType: .pdf, fileURL: "a")
        try await bookStore.upsert(a)
        try await positionStore.upsert(Position(bookId: a.id, locator: "page:1", percentComplete: 0.5))
        await vm.refresh()
        #expect(vm.books.count == 1)
        await vm.delete(a)
        #expect(vm.books.isEmpty)
        #expect(vm.readingNow.isEmpty)
        #expect(vm.filteredBooks.isEmpty)
    }

    @Test("Search debounce: setting text rapidly only runs the final filter")
    func searchDebounceCoalesces() async throws {
        let (vm, bookStore, _, userId, _) = await Self.setup()
        let alice = Book(userId: userId, title: "Alice", formatType: .epub, fileURL: "a")
        let bob = Book(userId: userId, title: "Bob", formatType: .epub, fileURL: "b")
        try await bookStore.upsert(alice); try await bookStore.upsert(bob)
        await vm.refresh()
        vm.debounceDuration = .milliseconds(50) // tighter for the test
        vm.searchText = "al"
        vm.searchText = "ali"
        vm.searchText = "alice"
        try? await Task.sleep(for: .milliseconds(120))
        #expect(vm.filteredBooks.map(\.title) == ["Alice"])
    }

    @Test("Empty search resets filteredBooks immediately to all books")
    func emptySearchResetsImmediately() async throws {
        let (vm, bookStore, _, userId, _) = await Self.setup()
        let alice = Book(userId: userId, title: "Alice", formatType: .epub, fileURL: "a")
        let bob = Book(userId: userId, title: "Bob", formatType: .epub, fileURL: "b")
        try await bookStore.upsert(alice); try await bookStore.upsert(bob)
        await vm.refresh()
        vm.searchText = "alice"
        vm.searchText = ""
        // No sleep — the empty path is synchronous.
        #expect(vm.filteredBooks.count == 2)
    }

    @Test("Missing user yields empty arrays")
    func noUserShortCircuits() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VM-nouser-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookStore = InMemoryBookStore()
        let positionStore = InMemoryPositionStore()
        let storage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
        let vm = LibraryViewModel(bookStore: bookStore, positionStore: positionStore,
                                  storage: storage, currentUserId: { nil },
                                  importCoordinator: ImportCoordinator(storage: storage, currentUserId: { nil }))
        await vm.refresh()
        #expect(vm.books.isEmpty)
        #expect(vm.readingNow.isEmpty)
    }
}
