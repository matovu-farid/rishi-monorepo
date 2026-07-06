import Testing
import Foundation
@testable import RishiCore

@Suite("ConversationsSyncAPI")
struct ConversationsSyncAPITests {

    // MARK: - Fixture

    private static let conversationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let createdAtMs: Int64 = 1_700_000_000_000
    private static let updatedAtMs: Int64 = 1_700_000_500_000

    private static func makeRow() -> ConversationRowWire {
        ConversationRowWire(
            id: conversationId,
            userId: "user_alice",
            bookId: "book_abc",
            title: "My chat",
            archived: false,
            createdAt: createdAtMs,
            updatedAt: updatedAtMs
        )
    }

    // MARK: - Tests

    @Test("ConversationsSyncEndpoint pins path + method")
    func conversationsSyncPathAndMethod() {
        let endpoint = ConversationsSyncEndpoint(body: .init(conversations: [Self.makeRow()]))
        #expect(endpoint.path == "/api/sync/conversations")
        #expect(endpoint.method == .POST)
    }

    @Test("ConversationsSyncEndpoint body encodes snake_case row fields")
    func conversationsSyncBodyEncodesSnakeCase() throws {
        let body = ConversationsSyncEndpoint.Body(conversations: [Self.makeRow()])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"conversations\""))
        #expect(str.contains("\"id\""))
        #expect(str.contains("\"user_id\""))
        #expect(str.contains("\"book_id\""))
        #expect(str.contains("\"title\""))
        #expect(str.contains("\"archived\""))
        #expect(str.contains("\"created_at\""))
        #expect(str.contains("\"updated_at\""))
    }

    @Test("ConversationsSyncEndpoint response decodes applied_count")
    func conversationsSyncResponseDecodesAppliedCount() throws {
        let json = #"{"applied_count": 3}"#
        let response = try JSONDecoder().decode(
            ConversationsSyncEndpoint.Response.self,
            from: Data(json.utf8)
        )
        #expect(response.appliedCount == 3)
    }

    @Test("ConversationsSyncSinceEndpoint encodes ?since=<ms_epoch>")
    func conversationsSyncSinceEncodesQuery() {
        let endpoint = ConversationsSyncSinceEndpoint(since: 1_700_000_000_000)
        #expect(endpoint.path == "/api/sync/conversations?since=1700000000000")
        #expect(endpoint.method == .GET)
    }

    @Test("ConversationsSyncSinceEndpoint omits ?since= when nil")
    func conversationsSyncSinceOmitsWhenNil() {
        let endpoint = ConversationsSyncSinceEndpoint(since: nil)
        #expect(endpoint.path == "/api/sync/conversations")
        #expect(endpoint.method == .GET)
    }

    @Test("ConversationsSyncSinceEndpoint response decodes rows with snake_case mapping")
    func conversationsSyncSinceResponseDecodes() throws {
        let json = """
        {
          "rows": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "user_id": "user_alice",
              "book_id": "book_abc",
              "title": "My chat",
              "archived": false,
              "created_at": 1700000000000,
              "updated_at": 1700000500000
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            ConversationsSyncSinceEndpoint.Response.self,
            from: Data(json.utf8)
        )
        #expect(response.rows.count == 1)
        let row = response.rows[0]
        #expect(row.id == Self.conversationId)
        #expect(row.userId == "user_alice")
        #expect(row.bookId == "book_abc")
        #expect(row.title == "My chat")
        #expect(row.archived == false)
        #expect(row.createdAt == Self.createdAtMs)
        #expect(row.updatedAt == Self.updatedAtMs)
    }
}
