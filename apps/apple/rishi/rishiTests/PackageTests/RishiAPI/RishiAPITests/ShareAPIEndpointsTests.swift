import Foundation
import Testing

@testable import rishi

@Suite("Share API endpoints")
struct ShareAPIEndpointsTests {
    @Test("create endpoint uses the worker share contract")
    func createEndpoint() throws {
        let endpoint = ShareCreateEndpoint(body: .init(
            idempotencyKey: "request-1",
            kind: .selection,
            bookIDs: ["book-1", "book-2"],
            delivery: .username,
            recipientUsername: "reader"
        ))
        #expect(endpoint.path == "/api/shares")
        let data = try JSONEncoder().encode(endpoint.body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["idempotency_key"] as? String == "request-1")
        #expect(json["book_ids"] as? [String] == ["book-1", "book-2"])
        #expect(json["recipient_username"] as? String == "reader")
    }

    @Test("preview endpoint URL-encodes the bearer token")
    func previewEndpoint() {
        let endpoint = SharePreviewEndpoint(token: "abc+/=")
        #expect(endpoint.path.hasPrefix("/api/shares/preview?token="))
        #expect(endpoint.path.contains("abc"))
    }

    @Test("accept endpoint is package-scoped")
    func acceptEndpoint() {
        let endpoint = ShareAcceptEndpoint(packageID: "package-1")
        #expect(endpoint.path == "/api/shares/package-1/accept")
        #expect(endpoint.method == .POST)
    }

    @Test("decodes the worker's reference-date expiry and download response")
    func responseDecoding() throws {
        let data = Data(#"{"id":"package-1","expires_at":800000000,"items":[{"id":"item-1","title":"Book","author":null,"format":"epub","file_size":12,"file_url":"https://files.test/book"}]}"#.utf8)
        let response = try JSONDecoder().decode(SharePackageResponse.self, from: data)
        #expect(response.id == "package-1")
        #expect(response.items?.count == 1)
        #expect(response.expiresAt == Date(timeIntervalSinceReferenceDate: 800000000))
    }
}
