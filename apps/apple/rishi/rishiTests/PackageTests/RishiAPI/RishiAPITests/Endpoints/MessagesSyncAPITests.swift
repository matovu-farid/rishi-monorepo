@testable import rishi
import Testing
import Foundation


@Suite("MessagesSyncAPI")
struct MessagesSyncAPITests {

    // MARK: - Fixture

    private static let messageId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let conversationId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let createdAtMs: Int64 = 1_700_000_000_000
    private static let updatedAtMs: Int64 = 1_700_000_000_000

    private static func makeRow() -> MessageRowWire {
        MessageRowWire(
            id: messageId,
            conversationId: conversationId,
            role: "user",
            content: "Hello, world",
            createdAt: createdAtMs,
            updatedAt: updatedAtMs
        )
    }

    // MARK: - Tests

    @Test("MessagesSyncEndpoint pins path + method")
    func messagesSyncPathAndMethod() {
        let endpoint = MessagesSyncEndpoint(body: .init(messages: [Self.makeRow()]))
        #expect(endpoint.path == "/api/sync/messages")
        #expect(endpoint.method == .POST)
    }

    @Test("MessagesSyncEndpoint body encodes snake_case row fields")
    func messagesSyncBodyEncodesSnakeCase() throws {
        let body = MessagesSyncEndpoint.Body(messages: [Self.makeRow()])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"messages\""))
        #expect(str.contains("\"id\""))
        #expect(str.contains("\"conversation_id\""))
        #expect(str.contains("\"role\""))
        #expect(str.contains("\"content\""))
        #expect(str.contains("\"created_at\""))
        #expect(str.contains("\"updated_at\""))
    }

    @Test("MessagesSyncEndpoint response decodes applied_count")
    func messagesSyncResponseDecodesAppliedCount() throws {
        let json = #"{"applied_count": 5}"#
        let response = try JSONDecoder().decode(
            MessagesSyncEndpoint.Response.self,
            from: Data(json.utf8)
        )
        #expect(response.appliedCount == 5)
    }

    @Test("MessagesSyncSinceEndpoint encodes ?since=<ms_epoch>")
    func messagesSyncSinceEncodesQuery() {
        let endpoint = MessagesSyncSinceEndpoint(since: 1_700_000_000_000)
        #expect(endpoint.path == "/api/sync/messages?since=1700000000000")
        #expect(endpoint.method == .GET)
    }

    @Test("MessagesSyncSinceEndpoint omits ?since= when nil")
    func messagesSyncSinceOmitsWhenNil() {
        let endpoint = MessagesSyncSinceEndpoint(since: nil)
        #expect(endpoint.path == "/api/sync/messages")
        #expect(endpoint.method == .GET)
    }

    @Test("MessagesSyncSinceEndpoint response decodes rows with snake_case mapping")
    func messagesSyncSinceResponseDecodes() throws {
        let json = """
        {
          "rows": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "conversation_id": "11111111-1111-1111-1111-111111111111",
              "role": "user",
              "content": "Hello, world",
              "created_at": 1700000000000,
              "updated_at": 1700000000000
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            MessagesSyncSinceEndpoint.Response.self,
            from: Data(json.utf8)
        )
        #expect(response.rows.count == 1)
        let row = response.rows[0]
        #expect(row.id == Self.messageId)
        #expect(row.conversationId == Self.conversationId)
        #expect(row.role == "user")
        #expect(row.content == "Hello, world")
        #expect(row.createdAt == Self.createdAtMs)
        #expect(row.updatedAt == Self.updatedAtMs)
    }
}
