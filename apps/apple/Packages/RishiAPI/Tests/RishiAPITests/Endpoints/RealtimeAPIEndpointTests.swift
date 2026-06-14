import Foundation
import Testing
@testable import RishiAPI

/// Contract tests for `POST /api/realtime/client_secrets` (Phase 25).
///
/// The endpoint migrated from GET to POST in Plan 25-08 so the worker
/// (Plan 25-06) can receive the optional book-context snapshot the iOS
/// reader has at session-start. Body keys are snake_case on the wire;
/// the Swift surface stays camelCase via `Body.CodingKeys`.
///
/// The response shape (`{client_secret: string, session_id: string}`)
/// did NOT change — iOS contract is stable.
@Suite("RealtimeClientSecretsEndpoint (Phase 25 POST)")
struct RealtimeAPIEndpointTests {

    private func encode(_ endpoint: RealtimeClientSecretsEndpoint) throws -> [String: Any] {
        let data = try JSONEncoder().encode(endpoint.body)
        let any = try JSONSerialization.jsonObject(with: data)
        return any as? [String: Any] ?? [:]
    }

    // MARK: - Method + path

    @Test("method is POST")
    func methodIsPOST() {
        let endpoint = RealtimeClientSecretsEndpoint()
        #expect(endpoint.method == .POST)
    }

    @Test("path has no query string")
    func pathHasNoQuery() {
        let endpoint = RealtimeClientSecretsEndpoint(language: "en")
        #expect(endpoint.path == "/api/realtime/client_secrets")
    }

    @Test("endpoint conforms to WorkerEndpointWithBody so WorkerClient encodes the body")
    func conformsToBodied() {
        let endpoint: any WorkerEndpoint = RealtimeClientSecretsEndpoint()
        #expect(endpoint as? (any WorkerEndpointWithBody) != nil)
    }

    // MARK: - Body encoding

    @Test("default init encodes to empty object")
    func defaultInitEncodesEmptyObject() throws {
        let endpoint = RealtimeClientSecretsEndpoint()
        let json = try encode(endpoint)
        #expect(json.isEmpty)
    }

    @Test("language-only encodes {\"language\":\"en\"}")
    func languageOnly() throws {
        let endpoint = RealtimeClientSecretsEndpoint(language: "en")
        let json = try encode(endpoint)
        #expect(json["language"] as? String == "en")
        #expect(json.count == 1)
    }

    @Test("full body uses snake_case wire keys")
    func fullBodyWireKeys() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let outline = BookOutlineDTO(
            title: "T",
            author: "A",
            chapters: ["c1"]
        )
        let snapshot = BookContextSnapshot(
            bookId: uuid,
            currentPage: 3,
            pageText: "hi",
            outline: outline,
            activeParagraphText: "para"
        )
        let endpoint = RealtimeClientSecretsEndpoint(language: "en", bookContext: snapshot)
        let json = try encode(endpoint)

        #expect(json["language"] as? String == "en")
        #expect((json["book_id"] as? String)?.uppercased() == uuid.uuidString.uppercased())
        #expect(json["current_page"] as? Int == 3)
        #expect(json["page_text"] as? String == "hi")
        #expect(json["active_paragraph_text"] as? String == "para")

        let outlineJSON = try #require(json["outline"] as? [String: Any])
        #expect(outlineJSON["title"] as? String == "T")
        #expect(outlineJSON["author"] as? String == "A")
        #expect(outlineJSON["chapters"] as? [String] == ["c1"])
    }

    @Test("body omits nil fields (sparse encoding)")
    func sparseEncoding() throws {
        let uuid = UUID()
        let snapshot = BookContextSnapshot(bookId: uuid)
        let endpoint = RealtimeClientSecretsEndpoint(bookContext: snapshot)
        let json = try encode(endpoint)

        // bookId encoded, all other context fields omitted, language omitted.
        #expect(json["book_id"] != nil)
        #expect(json["language"] == nil)
        #expect(json["current_page"] == nil)
        #expect(json["page_text"] == nil)
        #expect(json["active_paragraph_text"] == nil)
        #expect(json["outline"] == nil)
    }

    // MARK: - Response decoding (unchanged contract)

    @Test("ClientSecretResponse decodes {client_secret, session_id} unchanged")
    func responseDecodes() throws {
        let json = #"{"client_secret":"sk-xxx","session_id":"sess-123"}"#
        let decoded = try JSONDecoder().decode(
            RealtimeClientSecretsEndpoint.ClientSecretResponse.self,
            from: Data(json.utf8)
        )
        #expect(decoded.clientSecret == "sk-xxx")
        #expect(decoded.sessionId == "sess-123")
    }

    // MARK: - BookContextSnapshot value semantics

    @Test("BookContextSnapshot is Equatable and Codable round-trip")
    func snapshotRoundTrip() throws {
        let uuid = UUID()
        let original = BookContextSnapshot(
            bookId: uuid,
            currentPage: 7,
            pageText: "page text",
            outline: BookOutlineDTO(title: "Title", author: nil, chapters: ["ch1", "ch2"]),
            activeParagraphText: "para"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookContextSnapshot.self, from: data)
        #expect(decoded == original)
    }
}
