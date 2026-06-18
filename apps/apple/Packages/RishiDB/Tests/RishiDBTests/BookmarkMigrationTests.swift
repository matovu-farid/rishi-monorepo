import Foundation
import Testing
import GRDB
@testable import RishiDB

@Suite("v3_bookmarks migration")
struct BookmarkMigrationTests {

    @Test func bookmarkTableExistsAfterMigration() throws {
        let queue = try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))

        let tableName = try queue.read { db -> String? in
            try String.fetchOne(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?
            """, arguments: [Tables.Bookmarks.table])
        }
        #expect(tableName == Tables.Bookmarks.table)
    }

    @Test func bookmarkBookIdIndexExistsAfterMigration() throws {
        let queue = try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))

        let indexName = try queue.read { db -> String? in
            try String.fetchOne(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_bookmark_book_id'
            """)
        }
        #expect(indexName == "idx_bookmark_book_id")
    }

    @Test func bookmarkForeignKeyCascadeEnforced() async throws {
        let queue = try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))

        // Inserting a bookmark with a non-existent book_id MUST fail because
        // foreign_keys = ON and the bookmark table has a FK on book_id.
        var didThrow = false
        do {
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO \(Tables.Bookmarks.table)
                      (id, book_id, locator, created_at)
                    VALUES (?, ?, ?, ?)
                """, arguments: [UUID().uuidString, UUID().uuidString, "{}", Date().timeIntervalSince1970])
            }
        } catch {
            didThrow = true
        }
        #expect(didThrow == true)
    }
}
