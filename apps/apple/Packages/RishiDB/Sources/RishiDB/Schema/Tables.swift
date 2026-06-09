import Foundation

/// Column-name constants for every RishiDB table. Plan 02-06 stores reference
/// these instead of hand-stringing column names, so a typo in a column rename
/// becomes a compile error rather than a runtime SQL error.
///
/// Table names follow snake_case plural (`"books"`, `"sync_metadata"`).
/// Column names follow snake_case (`"user_id"`, `"percent_complete"`).
/// Mirrors electron's RISHI_* Drizzle schema field naming.
public enum Tables {

    public enum Books {
        public static let table = "books"

        public static let id              = "id"               // TEXT PK (UUID)
        public static let userId          = "user_id"          // TEXT
        public static let title           = "title"            // TEXT
        public static let author          = "author"           // TEXT?
        public static let formatType      = "format_type"      // TEXT (epub/pdf/mobi/azw3)
        public static let addedAt         = "added_at"         // REAL (seconds epoch)
        public static let openedAt        = "opened_at"        // REAL? (seconds epoch)
        public static let fileURL         = "file_url"         // TEXT (relative path)
        public static let coverPath       = "cover_path"       // TEXT?
        public static let positionId      = "position_id"      // TEXT? FK -> positions.id
        public static let conversationId  = "conversation_id"  // TEXT? FK -> conversations.id
    }

    public enum Positions {
        public static let table = "positions"

        public static let id               = "id"                // TEXT PK (UUID)
        public static let bookId           = "book_id"           // TEXT FK -> books.id
        public static let locator          = "locator"           // TEXT (CFI or page+offset JSON)
        public static let percentComplete  = "percent_complete"  // REAL 0..1
        public static let updatedAt        = "updated_at"        // REAL
    }

    public enum Highlights {
        public static let table = "highlights"

        public static let id            = "id"             // TEXT PK
        public static let bookId        = "book_id"        // TEXT FK -> books.id
        public static let locatorStart  = "locator_start"  // TEXT
        public static let locatorEnd    = "locator_end"    // TEXT
        public static let color         = "color"          // TEXT (yellow/green/blue/pink)
        public static let text          = "text"           // TEXT
        public static let note          = "note"           // TEXT?
        public static let createdAt     = "created_at"     // REAL
    }

    public enum Conversations {
        public static let table = "conversations"

        public static let id         = "id"          // TEXT PK
        public static let userId     = "user_id"     // TEXT
        public static let bookId     = "book_id"     // TEXT? FK -> books.id
        public static let title      = "title"       // TEXT
        public static let createdAt  = "created_at"  // REAL
        public static let updatedAt  = "updated_at"  // REAL
    }

    public enum Messages {
        public static let table = "messages"

        public static let id              = "id"               // TEXT PK
        public static let conversationId  = "conversation_id"  // TEXT FK -> conversations.id
        public static let role            = "role"             // TEXT (user/assistant/system)
        public static let content         = "content"          // TEXT
        public static let toolCalls       = "tool_calls"       // TEXT? (opaque JSON)
        public static let createdAt       = "created_at"       // REAL
    }

    public enum Users {
        public static let table = "users"

        public static let id           = "id"            // TEXT PK
        public static let email        = "email"         // TEXT
        public static let displayName  = "display_name"  // TEXT?
        public static let avatarURL    = "avatar_url"    // TEXT?
        public static let hasPro       = "has_pro"       // INTEGER (0/1)
        public static let createdAt    = "created_at"    // REAL
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
