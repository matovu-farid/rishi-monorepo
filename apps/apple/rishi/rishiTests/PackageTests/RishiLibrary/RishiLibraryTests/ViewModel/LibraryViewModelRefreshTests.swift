@testable import rishi
import Testing
import Foundation




/// A PositionStore that sleeps for ``perReadDelay`` on every read, so a
/// serial caller pays ``perReadDelay × N`` while a concurrent caller pays
/// roughly ``perReadDelay`` total.
///
/// Used by `LibraryViewModelRefreshTests` to assert that
/// `LibraryViewModel.refresh()` fans out position reads via a TaskGroup.
private final class SlowPositionStore: PositionStore, @unchecked Sendable {
    let perReadDelay: Duration
    let positions: [BookID: Position]

    init(perReadDelay: Duration, positions: [BookID: Position] = [:]) {
        self.perReadDelay = perReadDelay
        self.positions = positions
    }

    func position(for bookId: BookID) async throws -> Position? {
        try await Task.sleep(for: perReadDelay)
        return positions[bookId]
    }

    func upsert(_ position: Position) async throws {}
    func delete(_ id: PositionID) async throws {}
}

private final class SlowCoverExtractor: CoverExtractor, @unchecked Sendable {
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func extractCover(from _: URL) async -> Data? {
        try? await Task.sleep(for: delay)
        return Data([0, 1, 2])
    }
}

@MainActor
@Suite("LibraryViewModel.refresh — concurrent position fan-out (F-P0-03)")
struct LibraryViewModelRefreshTests {

    private static func makeVM(
        userId: UserID,
        bookStore: any BookStore,
        positionStore: any PositionStore,
        root: URL? = nil,
        coverExtractors: [String: any CoverExtractor] = [:]
    ) -> LibraryViewModel {
        let root = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VMRefresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookFileStorage(
            rootURL: root,
            bookStore: bookStore,
            coverExtractors: coverExtractors
        )
        return LibraryViewModel(
            bookStore: bookStore,
            positionStore: positionStore,
            storage: storage,
            currentUserId: { userId },
            importCoordinator: ImportCoordinator(storage: storage, currentUserId: { userId })
        )
    }

    @Test("refresh fans out positionStore reads concurrently rather than serially")
    func test_refresh_fansOutPositionReadsConcurrently() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<10 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            try await bookStore.upsert(b)
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: 0.5)
        }
        // 100 ms per read × 10 books = 1000 ms serial. Parallel target: < 300 ms.
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(100), positions: positions)
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        let clock = ContinuousClock()
        let elapsed = await clock.measure { await vm.refresh() }

        // Serial would take >= 1000 ms; with parallel fan-out we expect < 300 ms
        // even under heavy CI load. (Single 100ms sleep + scheduling overhead.)
        #expect(elapsed < .milliseconds(300),
                "refresh() took \(elapsed) — expected < 300ms via concurrent fan-out (serial would be ~1000ms)")
        #expect(vm.books.count == 10)
    }

    @Test("refresh overlaps position and cold cover resolution")
    func test_refreshOverlapsPositionAndCoverWork() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        let root = URL.temporaryDirectory
            .appendingPathComponent("VMRefresh-overlap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let relativeFile = "Books/overlap/book.pdf"
        let sourceURL = root.appendingPathComponent(relativeFile)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([7]).write(to: sourceURL)

        let book = Book(
            userId: userId,
            title: "Overlap",
            formatType: .pdf,
            fileURL: relativeFile
        )
        try await bookStore.upsert(book)
        let position = Position(bookId: book.id, locator: "loc", percentComplete: 0.5)
        let positionStore = SlowPositionStore(
            perReadDelay: .milliseconds(200),
            positions: [book.id: position]
        )
        let vm = Self.makeVM(
            userId: userId,
            bookStore: bookStore,
            positionStore: positionStore,
            root: root,
            coverExtractors: [
                "pdf": SlowCoverExtractor(delay: .milliseconds(200))
            ]
        )

        let elapsed = await ContinuousClock().measure {
            await vm.refresh()
        }

        #expect(elapsed < .milliseconds(360), "refresh took (elapsed); position and cover work should overlap")
        #expect(vm.position(for: book.id)?.bookId == book.id)
        #expect(vm.coverURLs[book.id] != nil)
    }

    @Test("refresh preserves correct (bookId → position) mapping after fan-out")
    func test_refresh_preservesPositionMap() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<5 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            try await bookStore.upsert(b)
            // Distinct percent values so we can detect mis-keyed pairings.
            let pct = Double(i + 1) * 0.1
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: pct)
        }
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(5), positions: positions)
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        await vm.refresh()

        for b in books {
            let mapped = vm.position(for: b.id)
            #expect(mapped != nil, "missing position for book \(b.title)")
            #expect(mapped?.bookId == b.id, "position landed under wrong bookId for \(b.title)")
            #expect(mapped?.percentComplete == positions[b.id]?.percentComplete)
        }
        // All 5 books are in-progress (0.1–0.5), but the shelf caps at 3.
        #expect(vm.readingNow.count == 3)
    }

    @Test("refresh handles partial nil results — only books with saved positions land in readingNow")
    func test_refresh_handlesPartialNilResults() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<6 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            try await bookStore.upsert(b)
        }
        // Only even-indexed books have positions; odd-indexed books return nil.
        for i in stride(from: 0, to: 6, by: 2) {
            let b = books[i]
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: 0.5)
        }
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(5), positions: positions)
        let vm = Self.makeVM(userId: userId, bookStore: bookStore, positionStore: positionStore)

        await vm.refresh()

        #expect(vm.books.count == 6)
        // Three even-indexed books have positions; three odd-indexed books do not.
        #expect(vm.positionsByBookId.count == 3)
        for i in 0..<6 {
            let mapped = vm.position(for: books[i].id)
            if i % 2 == 0 {
                #expect(mapped != nil, "expected position for book index \(i)")
            } else {
                #expect(mapped == nil, "expected NO position for book index \(i)")
            }
        }
        #expect(vm.readingNow.count == 3)
    }

    @Test("completed sync refreshes the mounted library and reveals newly synced books")
    func refreshesAfterSyncStatusTransitionsToIdle() async throws {
        let userId = UUID()
        let bookStore = InMemoryBookStore()
        let positionStore = SlowPositionStore(perReadDelay: .milliseconds(1))
        let vm = Self.makeVM(
            userId: userId,
            bookStore: bookStore,
            positionStore: positionStore
        )
        let status = SyncStatus(isRunning: true)
        let refreshes = RefreshEventRecorder()
        let observer = LibrarySyncCompletionRefreshObserver(
            refresh: {
                await vm.refresh()
                await refreshes.record()
            }
        )

        await observer.statusChanged(from: nil, to: status.snapshot())

        let syncedBook = Book(
            userId: userId,
            title: "Synced after completion",
            formatType: .pdf,
            fileURL: "synced.pdf"
        )
        try await bookStore.upsert(syncedBook)

        status.apply(SyncStatusSnapshot(
            lastSyncedAt: Date(),
            pendingCount: 0,
            isRunning: false,
            lastError: nil
        ))
        await observer.statusChanged(from: true, to: status.snapshot())

        #expect(await refreshes.count == 1)
        #expect(vm.books.map(\.id) == [syncedBook.id])
    }
}

private actor RefreshEventRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
