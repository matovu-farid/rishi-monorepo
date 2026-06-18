import Foundation

/// Column-name constants for every RishiDB table. Plan 02-06 stores reference
/// these instead of hand-stringing column names, so a typo in a column rename
/// becomes a compile error rather than a runtime SQL error.
///
/// Table names follow snake_case plural (`"books"`, `"sync_metadata"`).
/// Column names follow snake_case (`"user_id"`, `"percent_complete"`).
/// Mirrors electron's RISHI_* Drizzle schema field naming.
public enum Tables {

    enum Books {
        static let table = "books"

        static let id              = "id"               // TEXT PK (UUID)
        static let userId          = "user_id"          // TEXT
        static let title           = "title"            // TEXT
        static let author          = "author"           // TEXT?
        static let formatType      = "format_type"      // TEXT (epub/pdf/mobi/azw3)
        static let addedAt         = "added_at"         // REAL (seconds epoch)
        static let openedAt        = "opened_at"        // REAL? (seconds epoch)
        static let fileURL         = "file_url"         // TEXT (relative path)
        static let coverPath       = "cover_path"       // TEXT?
        static let positionId      = "position_id"      // TEXT? FK -> positions.id
        static let conversationId  = "conversation_id"  // TEXT? FK -> conversations.id
    }

    enum Positions {
        static let table = "positions"

        static let id               = "id"                // TEXT PK (UUID)
        static let bookId           = "book_id"           // TEXT FK -> books.id
        static let locator          = "locator"           // TEXT (CFI or page+offset JSON)
        static let percentComplete  = "percent_complete"  // REAL 0..1
        static let updatedAt        = "updated_at"        // REAL
    }

    enum Highlights {
        static let table = "highlights"

        static let id            = "id"             // TEXT PK
        static let bookId        = "book_id"        // TEXT FK -> books.id
        static let locatorStart  = "locator_start"  // TEXT
        static let locatorEnd    = "locator_end"    // TEXT
        static let color         = "color"          // TEXT (yellow/green/blue/pink)
        static let text          = "text"           // TEXT
        static let note          = "note"           // TEXT?
        static let createdAt     = "created_at"     // REAL
    }

    enum Bookmarks {
        static let table = "bookmark"

        static let id         = "id"          // TEXT PK
        static let bookId     = "book_id"     // TEXT FK -> books.id
        static let locator    = "locator"     // TEXT versioned locator JSON
        static let label      = "label"       // TEXT?
        static let snippet    = "snippet"     // TEXT?
        static let createdAt  = "created_at"  // REAL
    }

    enum Conversations {
        static let table = "conversations"

        static let id         = "id"          // TEXT PK
        static let userId     = "user_id"     // TEXT
        static let bookId     = "book_id"     // TEXT? FK -> books.id
        static let title      = "title"       // TEXT
        static let createdAt  = "created_at"  // REAL
        static let updatedAt  = "updated_at"  // REAL
    }

    enum Messages {
        static let table = "messages"

        static let id              = "id"               // TEXT PK
        static let conversationId  = "conversation_id"  // TEXT FK -> conversations.id
        static let role            = "role"             // TEXT (user/assistant/system)
        static let content         = "content"          // TEXT
        static let toolCalls       = "tool_calls"       // TEXT? (opaque JSON)
        static let createdAt       = "created_at"       // REAL
    }

    enum Users {
        static let table = "users"

        static let id           = "id"            // TEXT PK
        static let email        = "email"         // TEXT
        static let displayName  = "display_name"  // TEXT?
        static let avatarURL    = "avatar_url"    // TEXT?
        static let hasPro       = "has_pro"       // INTEGER (0/1)
        static let createdAt    = "created_at"    // REAL
    }

    public enum SyncMetadata {
        public static let table = "sync_metadata"

        public static let entityId      = "entity_id"       // TEXT PK
        public static let entityType    = "entity_type"     // TEXT
        public static let remoteEtag    = "remote_etag"     // TEXT?
        public static let lastSyncedAt  = "last_synced_at"  // REAL?
        public static let dirty         = "dirty"           // INTEGER (0/1)
    }
}
