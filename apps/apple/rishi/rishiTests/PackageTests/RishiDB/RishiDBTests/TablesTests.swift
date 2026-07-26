@testable import rishi
import Foundation
import Testing


@Suite("RishiDB Tables column-name constants")
struct TablesTests {

    @Test func bookTableConstantsMatchElectronSchema() {
        #expect(Tables.Books.table == "books")
        #expect(Tables.Books.id == "id")
        #expect(Tables.Books.userId == "user_id")
        #expect(Tables.Books.title == "title")
        #expect(Tables.Books.author == "author")
        #expect(Tables.Books.formatType == "format_type")
        #expect(Tables.Books.addedAt == "added_at")
        #expect(Tables.Books.openedAt == "opened_at")
        #expect(Tables.Books.fileURL == "file_url")
        #expect(Tables.Books.coverPath == "cover_path")
        #expect(Tables.Books.positionId == "position_id")
        #expect(Tables.Books.conversationId == "conversation_id")
    }

    @Test func positionsTableConstants() {
        #expect(Tables.Positions.table == "positions")
        #expect(Tables.Positions.id == "id")
        #expect(Tables.Positions.bookId == "book_id")
        #expect(Tables.Positions.locator == "locator")
        #expect(Tables.Positions.percentComplete == "percent_complete")
        #expect(Tables.Positions.updatedAt == "updated_at")
    }

    @Test func highlightsTableConstants() {
        #expect(Tables.Highlights.table == "highlights")
        #expect(Tables.Highlights.id == "id")
        #expect(Tables.Highlights.bookId == "book_id")
        #expect(Tables.Highlights.locatorStart == "locator_start")
        #expect(Tables.Highlights.locatorEnd == "locator_end")
        #expect(Tables.Highlights.color == "color")
        #expect(Tables.Highlights.text == "text")
        #expect(Tables.Highlights.note == "note")
        #expect(Tables.Highlights.createdAt == "created_at")
    }

    @Test func conversationsTableConstants() {
        #expect(Tables.Conversations.table == "conversations")
        #expect(Tables.Conversations.id == "id")
        #expect(Tables.Conversations.userId == "user_id")
        #expect(Tables.Conversations.bookId == "book_id")
        #expect(Tables.Conversations.title == "title")
        #expect(Tables.Conversations.createdAt == "created_at")
        #expect(Tables.Conversations.updatedAt == "updated_at")
    }

    @Test func messagesTableConstants() {
        #expect(Tables.Messages.table == "messages")
        #expect(Tables.Messages.id == "id")
        #expect(Tables.Messages.conversationId == "conversation_id")
        #expect(Tables.Messages.role == "role")
        #expect(Tables.Messages.content == "content")
        #expect(Tables.Messages.toolCalls == "tool_calls")
        #expect(Tables.Messages.createdAt == "created_at")
    }

    @Test func usersTableConstants() {
        #expect(Tables.Users.table == "users")
        #expect(Tables.Users.id == "id")
        #expect(Tables.Users.email == "email")
        #expect(Tables.Users.displayName == "display_name")
        #expect(Tables.Users.avatarURL == "avatar_url")
        #expect(Tables.Users.hasPro == "has_pro")
        #expect(Tables.Users.createdAt == "created_at")
    }

    @Test func syncMetadataTableConstants() {
        #expect(Tables.SyncMetadata.table == "sync_metadata")
        #expect(Tables.SyncMetadata.entityId == "entity_id")
        #expect(Tables.SyncMetadata.entityType == "entity_type")
        #expect(Tables.SyncMetadata.remoteEtag == "remote_etag")
        #expect(Tables.SyncMetadata.lastSyncedAt == "last_synced_at")
        #expect(Tables.SyncMetadata.dirty == "dirty")
    }
}
