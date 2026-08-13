import Foundation
import Testing

@testable import rishi

@Suite("Share API endpoints")
struct ShareAPIEndpointsTests {
    @Test("prepare endpoint uses the bounded worker contract")
    func prepareEndpoint() throws {
        let endpoint = SharePrepareEndpoint(body: .init(bookIDs: ["book-1", "book-2"]))
        #expect(endpoint.path == "/api/shares/prepare")
        #expect(endpoint.requiresDataUseConsent)

        let data = try JSONEncoder().encode(endpoint.body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["book_ids"] as? [String] == ["book-1", "book-2"])
    }

    @Test("decodes prepared links and per-book skips")
    func prepareResponseDecoding() throws {
        let data = Data(#"{"links":[{"book_id":"book-1","public":{"id":"package-public","generation":3,"expires_at":800000000,"link":"https://rishi.test/public"},"one_time":{"id":"package-one-time","generation":4,"expires_at":800000000,"link":"https://rishi.test/one-time"}}],"skipped":[{"book_id":"book-2","code":"SHARE_BOOK_NOT_READY"}]}"#.utf8)
        let response = try JSONDecoder().decode(SharePrepareResponse.self, from: data)
        let prepared = try #require(response.links.first)
        #expect(prepared.bookID == "book-1")
        #expect(prepared.public.id == "package-public")
        #expect(prepared.public.generation == 3)
        #expect(prepared.public.link == "https://rishi.test/public")
        #expect(prepared.oneTime.id == "package-one-time")
        #expect(response.skipped.first?.code == "SHARE_BOOK_NOT_READY")
    }

    @Test("create endpoint uses the worker share contract")
    func createEndpoint() throws {
        let endpoint = ShareCreateEndpoint(body: .init(
            idempotencyKey: "request-1",
            kind: .selection,
            bookIDs: ["book-1", "book-2"],
            access: .public
        ))
        #expect(endpoint.path == "/api/shares")
        let data = try JSONEncoder().encode(endpoint.body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["idempotency_key"] as? String == "request-1")
        #expect(json["book_ids"] as? [String] == ["book-1", "book-2"])
        #expect(json["delivery"] as? String == "link")
        #expect(json["access"] as? String == "public")
    }

    @Test("preview endpoint URL-encodes the bearer token")
    func previewEndpoint() {
        let endpoint = SharePreviewEndpoint(token: "abc+/=")
        #expect(endpoint.path.hasPrefix("/api/shares/preview?token="))
        #expect(endpoint.path.contains("abc"))
    }

    @Test("decodes the worker's reference-date expiry and download response")
    func responseDecoding() throws {
        let data = Data(#"{"id":"package-1","expires_at":800000000,"items":[{"id":"item-1","title":"Book","author":null,"format":"epub","file_size":12,"file_hash":"abc123","file_url":"https://files.test/book"}]}"#.utf8)
        let response = try JSONDecoder().decode(SharePackageResponse.self, from: data)
        #expect(response.id == "package-1")
        #expect(response.items?.count == 1)
        #expect(response.items?.first?.fileHash == "abc123")
        #expect(response.expiresAt == Date(timeIntervalSinceReferenceDate: 800000000))
    }
}
