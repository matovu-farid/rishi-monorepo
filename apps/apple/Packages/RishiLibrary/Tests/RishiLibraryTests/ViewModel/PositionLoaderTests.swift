import Testing
import Foundation
@testable import RishiLibrary
import RishiCore
import RishiTesting

/// A `PositionStore` that sleeps for `perReadDelay` on every read so a serial
/// caller pays `perReadDelay × N` while a concurrent caller pays roughly
/// `perReadDelay` total. Mirrors the helper in `LibraryViewModelRefreshTests`
/// — used here to assert `PositionLoader` fans out reads via a TaskGroup.
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

@Suite("PositionLoader")
struct PositionLoaderTests {

    @Test("fans out position reads concurrently rather than serially")
    func fansOutConcurrently() async throws {
        let userId = UUID()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<10 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: 0.5)
        }
        // 100 ms × 10 = 1000 ms serial; parallel target < 300 ms.
        let store = SlowPositionStore(perReadDelay: .milliseconds(100), positions: positions)
        let loader = PositionLoader(positionStore: store)

        let clock = ContinuousClock()
        var result: [BookID: Position] = [:]
        let elapsed = await clock.measure { result = await loader.positions(for: books) }

        #expect(elapsed < .milliseconds(300),
                "positions(for:) took \(elapsed) — expected < 300ms via concurrent fan-out")
        #expect(result.count == 10)
    }

    @Test("preserves correct bookId -> position mapping after fan-out")
    func preservesMapping() async throws {
        let userId = UUID()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<5 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
            let pct = Double(i + 1) * 0.1
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: pct)
        }
        let store = SlowPositionStore(perReadDelay: .milliseconds(5), positions: positions)
        let loader = PositionLoader(positionStore: store)

        let result = await loader.positions(for: books)

        for b in books {
            #expect(result[b.id]?.bookId == b.id)
            #expect(result[b.id]?.percentComplete == positions[b.id]?.percentComplete)
        }
    }

    @Test("omits books with no saved position")
    func omitsNilPositions() async throws {
        let userId = UUID()
        var books: [Book] = []
        var positions: [BookID: Position] = [:]
        for i in 0..<6 {
            let b = Book(userId: userId, title: "B\(i)", formatType: .pdf, fileURL: "f\(i)")
            books.append(b)
        }
        for i in stride(from: 0, to: 6, by: 2) {
            let b = books[i]
            positions[b.id] = Position(bookId: b.id, locator: "loc:\(i)", percentComplete: 0.5)
        }
        let store = SlowPositionStore(perReadDelay: .milliseconds(1), positions: positions)
        let loader = PositionLoader(positionStore: store)

        let result = await loader.positions(for: books)

        #expect(result.count == 3)
        for i in 0..<6 {
            if i % 2 == 0 {
                #expect(result[books[i].id] != nil)
            } else {
                #expect(result[books[i].id] == nil)
            }
        }
    }

    @Test("empty input returns empty map")
    func emptyInput() async {
        let loader = PositionLoader(positionStore: InMemoryPositionStore())
        let result = await loader.positions(for: [])
        #expect(result.isEmpty)
    }
}
