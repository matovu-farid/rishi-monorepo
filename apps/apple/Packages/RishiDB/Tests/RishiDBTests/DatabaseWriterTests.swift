import Foundation
import Testing
import GRDB
import RishiCore
@testable import RishiDB

/// Plan F-P0-?? — DatabaseQueue → DatabasePool migration.
///
/// Two contracts:
///
/// 1. Stores accept `any DatabaseWriter` so callers can swap between an
///    in-memory `DatabaseQueue` (tests) and an on-disk `DatabasePool`
///    (production) without rewriting the store layer. The store init
///    signature is the API surface we want to lock down — if someone
///    re-pins it to `DatabaseQueue` we lose the ability to use a Pool.
///
/// 2. `DatabasePool` allows concurrent readers. The whole point of the
///    migration is that `pool.read { ... }` calls fired from different
///    Tasks overlap in wall-clock time instead of serialising on a
///    single connection (which is what `DatabaseQueue` does). We assert
///    overlap by sleeping inside each read closure and measuring that
///    the total wallclock < N × sleep.
@Suite("RishiDB DatabaseWriter migration")
struct DatabaseWriterTests {

    // MARK: - Store init accepts any DatabaseWriter

    /// Compile-time contract: every GRDB store accepts `any DatabaseWriter`.
    /// If this stops compiling we have re-tightened the init signature back
    /// to a concrete `DatabaseQueue`/`DatabasePool` and broken the test
    /// seam — fix the init, not the test.
    @Test("Every GRDB store init accepts any DatabaseWriter")
    func storesAcceptAnyDatabaseWriter() throws {
        let writer: any DatabaseWriter = try RishiDB.makeDatabaseQueue(
            at: URL(fileURLWithPath: ":memory:")
        )
        _ = GRDBBookStore(dbQueue: writer)
        _ = GRDBPositionStore(dbQueue: writer)
        _ = GRDBHighlightStore(dbQueue: writer)
        _ = GRDBConversationStore(dbQueue: writer)
        _ = GRDBMessageStore(dbQueue: writer)
    }

    // MARK: - DatabasePool concurrent reads

    /// `RishiDB.makeDatabasePool(at:)` returns a real Pool with WAL + foreign
    /// keys enabled and the v1 migration applied. We can read/write through
    /// it via the `DatabaseWriter` protocol.
    @Test("makeDatabasePool opens a usable on-disk pool with migrations applied")
    func makeDatabasePoolOpensAndMigrates() async throws {
        let url = try tmpDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let pool = try RishiDB.makeDatabasePool(at: url)

        // Migration ran — `books` table exists. Insert + read.
        let userId = UUID()
        let book = Book(
            userId: userId,
            title: "Pool Test",
            formatType: .epub,
            fileURL: "books/p.epub"
        )
        let store = GRDBBookStore(dbQueue: pool)
        try await store.upsert(book)
        let fetched = try await store.books(for: userId)
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Pool Test")
    }

    /// `DatabasePool.read { }` calls fired from parallel Tasks must overlap
    /// in wallclock time. A `DatabaseQueue` would serialise them — if this
    /// regresses, the whole point of the migration is gone.
    ///
    /// We fire 4 concurrent reads that each sleep ~200ms inside the read
    /// closure. Serial execution = 4 × 200ms = 800ms+. With Pool the four
    /// reads overlap; the total should be well under that budget. We use
    /// a generous 600ms ceiling to absorb CI variance — even at 600ms the
    /// overlap is conclusive (would be impossible under serial execution
    /// of 4 × 200ms sleeps).
    @Test("DatabasePool reads run concurrently (not serial)")
    func poolReadsRunConcurrently() async throws {
        let url = try tmpDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let pool = try RishiDB.makeDatabasePool(at: url)

        // Seed one book so the read returns something concrete.
        let userId = UUID()
        let store = GRDBBookStore(dbQueue: pool)
        try await store.upsert(Book(
            userId: userId,
            title: "Seed",
            formatType: .epub,
            fileURL: "books/s.epub"
        ))

        let sleepNanos: UInt64 = 200_000_000  // 200ms
        let parallelism = 4

        let clock = ContinuousClock()
        let start = clock.now

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<parallelism {
                group.addTask {
                    try await pool.read { db -> Void in
                        // Hold the read connection for ~200ms. Under a
                        // Pool this still allows other readers to make
                        // progress on their own connections in parallel.
                        // Under a Queue this would block every other
                        // reader behind us.
                        let _: Int? = try Int.fetchOne(
                            db,
                            sql: "SELECT COUNT(*) FROM \(Tables.Books.table)"
                        )
                        Thread.sleep(forTimeInterval: Double(sleepNanos) / 1_000_000_000.0)
                    }
                }
            }
            try await group.waitForAll()
        }

        let elapsed = clock.now - start
        let serialBudget = Duration.nanoseconds(Int64(sleepNanos) * Int64(parallelism))
        // Concurrent execution should complete in well under the serial
        // budget. A 600ms ceiling against an 800ms serial floor proves
        // overlap without being flaky on slow CI.
        #expect(elapsed < (serialBudget - .milliseconds(200)),
                "Pool reads took \(elapsed) — expected < \(serialBudget - .milliseconds(200)) (serial would have taken \(serialBudget))")
    }

    // MARK: - Helpers

    private func tmpDBURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rishi.sqlite")
    }
}
