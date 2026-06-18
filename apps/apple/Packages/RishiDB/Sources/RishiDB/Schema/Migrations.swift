import Foundation
import GRDB

/// Forward-only schema migrator. Identifiers (`v1_initial`, `v2_placeholder`)
/// are registered in order and applied exactly once per database. GRDB's
/// `DatabaseMigrator` tracks applied migrations in the `grdb_migrations` table
/// and never re-runs or rolls back, satisfying requirement DB-02.
///
/// Internal to RishiDB; consumers reach the migrator transitively through
/// `RishiDB.makeDatabaseQueue(at:)`.
enum Migrations {

    /// Singleton migrator. Configured once at module load.
    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()

        // v1_initial — creates all 7 tables matching electron RISHI_* Drizzle schema.
        m.registerMigration("v1_initial") { db in
            // books
            try db.execute(sql: """
                CREATE TABLE \(Tables.Books.table) (
                    \(Tables.Books.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Books.userId) TEXT NOT NULL,
                    \(Tables.Books.title) TEXT NOT NULL,
                    \(Tables.Books.author) TEXT,
                    \(Tables.Books.formatType) TEXT NOT NULL,
                    \(Tables.Books.addedAt) REAL NOT NULL,
                    \(Tables.Books.openedAt) REAL,
                    \(Tables.Books.fileURL) TEXT NOT NULL,
                    \(Tables.Books.coverPath) TEXT,
                    \(Tables.Books.positionId) TEXT,
                    \(Tables.Books.conversationId) TEXT
                )
            """)

            // positions
            try db.execute(sql: """
                CREATE TABLE \(Tables.Positions.table) (
                    \(Tables.Positions.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Positions.bookId) TEXT NOT NULL,
                    \(Tables.Positions.locator) TEXT NOT NULL,
                    \(Tables.Positions.percentComplete) REAL NOT NULL DEFAULT 0,
                    \(Tables.Positions.updatedAt) REAL NOT NULL,
                    FOREIGN KEY (\(Tables.Positions.bookId)) REFERENCES \(Tables.Books.table)(\(Tables.Books.id)) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_positions_book_id ON \(Tables.Positions.table)(\(Tables.Positions.bookId))")

            // highlights
            try db.execute(sql: """
                CREATE TABLE \(Tables.Highlights.table) (
                    \(Tables.Highlights.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Highlights.bookId) TEXT NOT NULL,
                    \(Tables.Highlights.locatorStart) TEXT NOT NULL,
                    \(Tables.Highlights.locatorEnd) TEXT NOT NULL,
                    \(Tables.Highlights.color) TEXT NOT NULL,
                    \(Tables.Highlights.text) TEXT NOT NULL,
                    \(Tables.Highlights.note) TEXT,
                    \(Tables.Highlights.createdAt) REAL NOT NULL,
                    FOREIGN KEY (\(Tables.Highlights.bookId)) REFERENCES \(Tables.Books.table)(\(Tables.Books.id)) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_highlights_book_id ON \(Tables.Highlights.table)(\(Tables.Highlights.bookId))")

            // conversations
            try db.execute(sql: """
                CREATE TABLE \(Tables.Conversations.table) (
                    \(Tables.Conversations.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Conversations.userId) TEXT NOT NULL,
                    \(Tables.Conversations.bookId) TEXT,
                    \(Tables.Conversations.title) TEXT NOT NULL,
                    \(Tables.Conversations.createdAt) REAL NOT NULL,
                    \(Tables.Conversations.updatedAt) REAL NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_conversations_book_id ON \(Tables.Conversations.table)(\(Tables.Conversations.bookId))")
            try db.execute(sql: "CREATE INDEX idx_conversations_user_id ON \(Tables.Conversations.table)(\(Tables.Conversations.userId))")

            // messages
            try db.execute(sql: """
                CREATE TABLE \(Tables.Messages.table) (
                    \(Tables.Messages.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Messages.conversationId) TEXT NOT NULL,
                    \(Tables.Messages.role) TEXT NOT NULL,
                    \(Tables.Messages.content) TEXT NOT NULL,
                    \(Tables.Messages.toolCalls) TEXT,
                    \(Tables.Messages.createdAt) REAL NOT NULL,
                    FOREIGN KEY (\(Tables.Messages.conversationId)) REFERENCES \(Tables.Conversations.table)(\(Tables.Conversations.id)) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_messages_conversation_id ON \(Tables.Messages.table)(\(Tables.Messages.conversationId))")

            // users
            try db.execute(sql: """
                CREATE TABLE \(Tables.Users.table) (
                    \(Tables.Users.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Users.email) TEXT NOT NULL,
                    \(Tables.Users.displayName) TEXT,
                    \(Tables.Users.avatarURL) TEXT,
                    \(Tables.Users.hasPro) INTEGER NOT NULL DEFAULT 0,
                    \(Tables.Users.createdAt) REAL NOT NULL
                )
            """)

            // sync_metadata
            try db.execute(sql: """
                CREATE TABLE \(Tables.SyncMetadata.table) (
                    \(Tables.SyncMetadata.entityId) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.SyncMetadata.entityType) TEXT NOT NULL,
                    \(Tables.SyncMetadata.remoteEtag) TEXT,
                    \(Tables.SyncMetadata.lastSyncedAt) REAL,
                    \(Tables.SyncMetadata.dirty) INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_sync_metadata_dirty ON \(Tables.SyncMetadata.table)(\(Tables.SyncMetadata.dirty))")
        }

        // v2_placeholder — intentional no-op so future v2 work has a registered
        // slot that GRDB will skip cleanly. Replace with the real change when
        // the time comes.
        m.registerMigration("v2_placeholder") { _ in
            // intentionally empty
        }

        // v3_bookmarks — adds the bookmark table for the reader bookmark slice
        // (Phase 37). Forward-only: never modify v1_initial or v2_placeholder.
        // Mirrors the highlights table shape minus color/selection-range; a single
        // versioned locator column plus optional label/snippet.
        m.registerMigration("v3_bookmarks") { db in
            try db.execute(sql: """
                CREATE TABLE \(Tables.Bookmarks.table) (
                    \(Tables.Bookmarks.id) TEXT PRIMARY KEY NOT NULL,
                    \(Tables.Bookmarks.bookId) TEXT NOT NULL,
                    \(Tables.Bookmarks.locator) TEXT NOT NULL,
                    \(Tables.Bookmarks.label) TEXT,
                    \(Tables.Bookmarks.snippet) TEXT,
                    \(Tables.Bookmarks.createdAt) REAL NOT NULL,
                    FOREIGN KEY (\(Tables.Bookmarks.bookId)) REFERENCES \(Tables.Books.table)(\(Tables.Books.id)) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_bookmark_book_id ON \(Tables.Bookmarks.table)(\(Tables.Bookmarks.bookId))")
        }

        return m
    }()
}
