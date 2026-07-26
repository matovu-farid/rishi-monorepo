@testable import rishi
import Testing
import Foundation




@Suite("ChatRequest encoding")
struct ChatRequestEncodingTests {

    private func encode(_ request: ChatRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test("encodes book_id as lowercase uuidString and includes query")
    func encodesBookIdLowercase() throws {
        let bookId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = ChatRequest(bookId: bookId, query: "what is X?")
        let json = try encode(request)
        #expect(json.contains("\"book_id\":\"11111111-1111-1111-1111-111111111111\""))
        #expect(json.contains("\"query\":\"what is X?\""))
    }

    @Test("encodes book_id lowercased even when source UUID is uppercase")
    func encodesBookIdLowercasesUppercaseSource() throws {
        let bookId = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        let request = ChatRequest(bookId: bookId, query: "q")
        let json = try encode(request)
        #expect(json.contains("\"book_id\":\"abcdef12-3456-7890-abcd-ef1234567890\""))
    }

    @Test("omits book_id key entirely when nil")
    func omitsBookIdWhenNil() throws {
        let request = ChatRequest(bookId: nil, query: "hi")
        let json = try encode(request)
        #expect(!json.contains("book_id"))
        #expect(json.contains("\"query\":\"hi\""))
    }

    @Test("never includes embedding or vector fields (cloud RAG only)")
    func neverIncludesEmbeddingOrVectorFields() throws {
        let bookId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = ChatRequest(bookId: bookId, query: "what is X?")
        let json = try encode(request)
        #expect(!json.lowercased().contains("embedding"))
        #expect(!json.lowercased().contains("vector"))
    }
}

@Suite("ChatResponseChunk decoding")
struct ChatResponseChunkDecodingTests {

    private func decode(_ json: String) throws -> ChatResponseChunk {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ChatResponseChunk.self, from: data)
    }

    @Test("decodes {\"delta\":\"hello\"}")
    func decodesDelta() throws {
        let chunk = try decode(#"{"delta":"hello"}"#)
        #expect(chunk.delta == "hello")
        #expect(chunk.toolCall == nil)
        #expect(chunk.done == nil)
    }

    @Test("decodes {\"done\":true}")
    func decodesDone() throws {
        let chunk = try decode(#"{"done":true}"#)
        #expect(chunk.delta == nil)
        #expect(chunk.toolCall == nil)
        #expect(chunk.done == true)
    }

    @Test("decodes snake-case tool_call into toolCall")
    func decodesToolCall() throws {
        let chunk = try decode(#"{"tool_call":"{\"name\":\"x\"}"}"#)
        #expect(chunk.delta == nil)
        #expect(chunk.toolCall == "{\"name\":\"x\"}")
        #expect(chunk.done == nil)
    }

    @Test("decodes empty delta string")
    func decodesEmptyDelta() throws {
        let chunk = try decode(#"{"delta":""}"#)
        #expect(chunk.delta == "")
    }

    @Test("decodes empty object (all fields nil)")
    func decodesEmptyObject() throws {
        let chunk = try decode("{}")
        #expect(chunk.delta == nil)
        #expect(chunk.toolCall == nil)
        #expect(chunk.done == nil)
    }
}

@Suite("ChatStreamEndpoint conformance")
struct ChatStreamEndpointConformanceTests {

    private func makeEndpoint() -> ChatStreamEndpoint {
        let bookId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        return ChatStreamEndpoint(body: ChatRequest(bookId: bookId, query: "hello"))
    }

    @Test("method is POST")
    func methodIsPOST() {
        let endpoint = makeEndpoint()
        #expect(endpoint.method == .POST)
    }

    @Test("path is /api/chat")
    func pathIsApiChat() {
        let endpoint = makeEndpoint()
        #expect(endpoint.path == "/api/chat")
    }

    @Test("conforms to WorkerStreamingEndpointWithBody")
    func conformsToWorkerStreamingEndpointWithBody() {
        // Compile-time check: assigning to the existential proves conformance.
        let endpoint = makeEndpoint()
        let erased: any WorkerStreamingEndpointWithBody = endpoint
        #expect(erased.path == "/api/chat")
        #expect(erased.method == .POST)
    }

    @Test("body round-trips through JSONEncoder and contains query field")
    func bodyRoundTripsContainsQuery() throws {
        let endpoint = makeEndpoint()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(endpoint.body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["query"] as? String == "hello")
        #expect(json["book_id"] as? String == "22222222-2222-2222-2222-222222222222")
    }
}
