@testable import rishi
import Foundation
import Testing




/// Proves that store calls emit `Log.event` breadcrumbs in the expected shape.
@Suite("RishiDB breadcrumbs", .serialized)
struct BreadcrumbsTests {

    /// Thread-safe capture sink. Using a class with a lock-guarded array keeps
    /// the closure-captured state safe across the actor-isolated `notify(...)`
    /// calls without dragging Sendable annotations into the test body.
    private final class CaptureSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(name: String, level: LogLevel, data: [String: String]?)] = []

        func append(_ name: String, _ level: LogLevel, _ data: [String: String]?) {
            lock.lock(); defer { lock.unlock() }
            events.append((name, level, data))
        }

        func snapshot() -> [(name: String, level: LogLevel, data: [String: String]?)] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    @Test func upsertEmitsDbWriteBreadcrumb() async throws {
        Log._testCapture.reset()
        defer { Log._testCapture.reset() }

        let sink = CaptureSink()
        Log._testCapture.handler = { name, level, data in
            sink.append(name, level, data)
        }

        let store = SwiftDataBookStore(
            dbStore: try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        )
        let book = Book(
            userId: UUID(),
            title: "Breadcrumb Trail",
            formatType: .epub,
            fileURL: "books/x.epub"
        )
        try await store.upsert(book)

        let captures = sink.snapshot()
        // `Log._testCapture.handler` is a process-global sink and other suites run
        // in parallel, so the buffer can interleave foreign `db.write` crumbs from
        // other stores (messages, bookmarks, ...). Match on table too so we assert
        // against THIS store's upsert rather than whatever landed first.
        let writeCrumb = captures.first {
            $0.name == "db.write"
                && $0.data?["operation"] == "upsert"
                && $0.data?["table"] == Tables.Books.table
        }
        #expect(writeCrumb != nil, "expected a db.write/upsert breadcrumb for books")
        #expect(writeCrumb?.data?["table"] == "books")
        #expect(writeCrumb?.level == .debug)
    }

    @Test func readEmitsDbReadBreadcrumb() async throws {
        Log._testCapture.reset()
        defer { Log._testCapture.reset() }

        let sink = CaptureSink()
        Log._testCapture.handler = { name, level, data in
            sink.append(name, level, data)
        }

        let store = SwiftDataBookStore(
            dbStore: try RishiDB.makeStore(at: URL(fileURLWithPath: ":memory:"))
        )
        _ = try await store.books(for: UUID())

        let captures = sink.snapshot()
        let readCrumb = captures.first {
            $0.name == "db.read" && $0.data?["operation"] == "books_for_user"
        }
        #expect(readCrumb != nil, "expected a db.read/books_for_user breadcrumb")
        #expect(readCrumb?.data?["table"] == "books")
    }

    @Test func weirdPathStillBootstrapsStore() async throws {
        // SwiftData does not fail eagerly on this URL, so the useful check here
        // is that we can still bootstrap and perform a round-trip write.
        let badURL = URL(fileURLWithPath: "/dev/null/nope/cannot-open.sqlite")
        let userId = UUID()
        let store = try RishiDB.makeStore(at: badURL)
        let bookStore = SwiftDataBookStore(dbStore: store)
        let book = Book(
            userId: userId,
            title: "Bad Path",
            formatType: .epub,
            fileURL: "books/bad.epub"
        )
        try await bookStore.upsert(book)
        let fetched = try await bookStore.books(for: userId)
        #expect(fetched.count == 1)
    }
}
