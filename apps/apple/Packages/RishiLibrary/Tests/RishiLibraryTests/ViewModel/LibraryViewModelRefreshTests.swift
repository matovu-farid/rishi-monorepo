import Testing
import Foundation
@testable import RishiLibrary
import RishiCore
import RishiTesting

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

@MainActor
@Suite("LibraryViewModel.refresh — concurrent position fan-out (F-P0-03)")
struct LibraryViewModelRefreshTests {

    private static func makeVM(
        userId: UserID,
        bookStore: any BookStore,
        positionStore: any PositionStore
    ) -> LibraryViewModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VMRefresh-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookFileStorage(rootURL: root, bookStore: bookStore, coverExtractors: [:])
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
        // All 5 books are in-progress (0.1–0.5).
        #expect(vm.readingNow.count == 5)
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
}
