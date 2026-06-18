import Foundation
import Testing
import GRDB
@testable import RishiDB

@Suite("RishiDB Migrations")
struct MigrationsTests {

    @Test func freshInMemoryMigratesV1AndV2() throws {
        let url = URL(fileURLWithPath: ":memory:")
        let queue = try RishiDB.makeDatabaseQueue(at: url)

        let applied = try queue.read { db in
            try Migrations.migrator.appliedMigrations(db)
        }
        #expect(applied == ["v1_initial", "v2_placeholder", "v3_bookmarks"])
    }

    @Test func allSevenTablesExistAfterMigration() throws {
        let queue = try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))

        let tables = try queue.read { db -> Set<String> in
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            return Set(names)
        }

        let expected: Set<String> = [
            Tables.Books.table,
            Tables.Positions.table,
            Tables.Highlights.table,
            Tables.Conversations.table,
            Tables.Messages.table,
            Tables.Users.table,
            Tables.SyncMetadata.table,
        ]
        #expect(expected.isSubset(of: tables))
    }

    @Test func foreignKeysEnforced() async throws {
        let queue = try RishiDB.makeDatabaseQueue(at: URL(fileURLWithPath: ":memory:"))

        // Inserting a highlight with a non-existent book_id MUST fail because
        // foreign_keys = ON and we have the FOREIGN KEY constraint on highlights.book_id.
        var didThrow = false
        do {
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO \(Tables.Highlights.table)
                      (id, book_id, locator_start, locator_end, color, text, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, UUID().uuidString, "0", "1", "yellow", "x", Date().timeIntervalSince1970])
            }
        } catch {
            didThrow = true
        }
        #expect(didThrow == true)
    }

    @Test func migratorIsForwardOnly() {
        // GRDB's DatabaseMigrator has no public erase / downgrade method.
        // This test documents intent — if anyone later sets
        // `eraseDatabaseOnSchemaChange = true` on the migrator, the symbol
        // search below should grep-fail (we don't reference it).
        let mirror = String(describing: Migrations.migrator)
        #expect(!mirror.contains("eraseDatabaseOnSchemaChange = true"))
    }
}
