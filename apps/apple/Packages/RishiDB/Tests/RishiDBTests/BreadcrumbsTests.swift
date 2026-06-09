import Foundation
import Testing
import GRDB
import RishiCore
import RishiLogging
@testable import RishiDB

/// Proves that GRDB store calls emit `Log.event` breadcrumbs in the shape
/// promised by plan 02-06. The `.serialized` trait keeps these tests off the
/// shared `Log._testCapture` hook concurrently with anything else.
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

        let store = GRDBBookStore(
            dbQueue: try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))
        )
        let book = Book(
            userId: UUID(),
            title: "Breadcrumb Trail",
            formatType: .epub,
            fileURL: "books/x.epub"
        )
        try await store.upsert(book)

        let captures = sink.snapshot()
        let writeCrumb = captures.first {
            $0.name == "db.write" && $0.data?["operation"] == "upsert"
        }
        #expect(writeCrumb != nil, "expected a db.write/upsert breadcrumb")
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

        let store = GRDBBookStore(
            dbQueue: try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))
        )
        _ = try await store.books(for: UUID())

        let captures = sink.snapshot()
        let readCrumb = captures.first {
            $0.name == "db.read" && $0.data?["operation"] == "books_for_user"
        }
        #expect(readCrumb != nil, "expected a db.read/books_for_user breadcrumb")
        #expect(readCrumb?.data?["table"] == "books")
    }

    @Test func badPathFailsToOpenQueue() async {
        // Companion smoke: error paths bubble out as throws. We can't directly
        // intercept Log.error inside swift test, but we can confirm the bad path
        // does fail so the GRDB store error catches stay reachable in real use.
        let badURL = URL(fileURLWithPath: "/dev/null/nope/cannot-open.sqlite")
        do {
            _ = try RishiDB.makeDatabaseQueue(at: badURL)
            Issue.record("expected makeDatabaseQueue to throw on bad path")
        } catch {
            // expected
        }
    }
}
