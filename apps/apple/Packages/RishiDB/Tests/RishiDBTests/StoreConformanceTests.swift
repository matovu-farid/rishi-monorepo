import Foundation
import Testing
import GRDB
import RishiCore
import RishiTesting
@testable import RishiDB

/// Run every RishiTesting conformance helper against the GRDB-backed stores.
/// These are the same helpers that exercise the InMemory* fakes in RishiTesting's
/// own tests — passing both proves contract-equivalence and lets feature code
/// swap implementations without rewriting tests.
@Suite("RishiDB store conformance")
struct StoreConformanceTests {

    /// Conformance tests deliberately exercise the protocol contract — they
    /// insert highlights/positions/messages with synthetic parent ids that
    /// have no `books`/`conversations` row, so the test queue runs with FK
    /// enforcement disabled. Real callers always upsert the parent first;
    /// FK behaviour is covered by `MigrationsTests.foreignKeysEnforced`.
    ///
    /// `defer_foreign_keys` only postpones checks until COMMIT — it doesn't
    /// skip them — so plan 02-06's per-txn pragma is insufficient on its
    /// own. We bypass `RishiDB.makeDatabaseQueue(at:)` here and configure a
    /// queue without the FK preparer, then run the migrator manually.
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
        }
        let queue = try DatabaseQueue(configuration: config)
        try Migrations.migrator.migrate(queue)
        return queue
    }

    @Test func grdbBookStoreSatisfiesContract() async throws {
        let store = GRDBBookStore(dbQueue: try makeQueue())
        try await assertBookStoreConformance(store)
    }

    @Test func grdbHighlightStoreSatisfiesContract() async throws {
        let store = GRDBHighlightStore(dbQueue: try makeQueue())
        try await assertHighlightStoreConformance(store)
    }

    @Test func grdbPositionStoreSatisfiesContract() async throws {
        let store = GRDBPositionStore(dbQueue: try makeQueue())
        try await assertPositionStoreConformance(store)
    }

    @Test func grdbConversationStoreSatisfiesContract() async throws {
        let store = GRDBConversationStore(dbQueue: try makeQueue())
        try await assertConversationStoreConformance(store)
    }

    @Test func grdbMessageStoreSatisfiesContract() async throws {
        let store = GRDBMessageStore(dbQueue: try makeQueue())
        try await assertMessageStoreConformance(store)
    }
}
