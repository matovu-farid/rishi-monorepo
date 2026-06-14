import Testing
import Foundation
@testable import RishiVoice
import RishiCore
import RishiAPI

/// Tests for the Phase 25 (Plan 25-08) shape change on
/// `EphemeralKeyFetcher.fetch(...)`. The protocol method now takes an
/// optional `BookContextSnapshot`; a default-arg extension preserves the
/// old `fetch(language:)` call site used by the Plan 10-03 reconnect path
/// in `RealtimeVoiceSession.handleTransientDisconnect()`.
///
/// `.serialized` because `BookContextStubURLProtocol` keeps a
/// `nonisolated(unsafe)` static responder; concurrent tests would race it.
@Suite("EphemeralKeyFetcher book-context wiring", .serialized)
struct EphemeralKeyFetcherBookContextTests {

    // MARK: - Helpers

    private func makeWorkerClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BookContextStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://api.fidexa.org")!,
            session: session,
            tokenProvider: StaticTokenProvider("stub-token")
        )
    }

    private func okResponder(captureBodyInto box: BodyCaptureBox) -> (URLRequest) -> (Int, Data) {
        return { req in
            // URLProtocol stubs see the request body via httpBodyStream when
            // URLSession serialises it for upload. Drain it into the box.
            if let stream = req.httpBodyStream {
                box.body = Self.drain(stream)
            } else {
                box.body = req.httpBody
            }
            box.method = req.httpMethod
            box.urlString = req.url?.absoluteString
            let body = #"{"client_secret":"sk","session_id":"sess"}"#
            return (200, Data(body.utf8))
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    // MARK: - Tests

    @Test("fetch(language:) default-arg overload sends no book_id (Plan 10-03 reconnect path)")
    func reconnectPathSendsNoBookId() async throws {
        BookContextStubURLProtocol.reset()
        let captured = BodyCaptureBox()
        BookContextStubURLProtocol.responder = okResponder(captureBodyInto: captured)

        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())
        // Mirrors RealtimeVoiceSession.handleTransientDisconnect which calls
        // `keyFetcher.fetch(language: "en")` with no book context.
        let key = try await fetcher.fetch(language: "en")
        #expect(key.secret == "sk")

        #expect(captured.method == "POST")
        #expect(captured.urlString?.hasSuffix("/api/realtime/client_secrets") == true)
        let json = try captured.json()
        #expect(json["language"] as? String == "en")
        #expect(json["book_id"] == nil)
        #expect(json["current_page"] == nil)
        #expect(json["active_paragraph_text"] == nil)
    }

    @Test("fetch(language:bookContext:) sends snake_case book_id from snapshot")
    func sendsSnapshotFields() async throws {
        BookContextStubURLProtocol.reset()
        let captured = BodyCaptureBox()
        BookContextStubURLProtocol.responder = okResponder(captureBodyInto: captured)

        let bookId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let outline = BookOutlineDTO(title: "Title", author: "Author", chapters: ["c1", "c2"])
        let snapshot = BookContextSnapshot(
            bookId: bookId,
            currentPage: 12,
            pageText: "current page text",
            outline: outline,
            activeParagraphText: "active para"
        )

        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())
        let key = try await fetcher.fetch(language: "en", bookContext: snapshot)
        #expect(key.secret == "sk")
        #expect(key.sessionId == "sess")

        let json = try captured.json()
        #expect(json["language"] as? String == "en")
        #expect((json["book_id"] as? String)?.uppercased() == bookId.uuidString.uppercased())
        #expect(json["current_page"] as? Int == 12)
        #expect(json["page_text"] as? String == "current page text")
        #expect(json["active_paragraph_text"] as? String == "active para")
        let outlineJSON = try #require(json["outline"] as? [String: Any])
        #expect(outlineJSON["title"] as? String == "Title")
        #expect(outlineJSON["chapters"] as? [String] == ["c1", "c2"])
    }

    @Test("fetch(language: nil, bookContext: snapshot) omits language but sends book_id")
    func nilLanguageWithSnapshot() async throws {
        BookContextStubURLProtocol.reset()
        let captured = BodyCaptureBox()
        BookContextStubURLProtocol.responder = okResponder(captureBodyInto: captured)

        let snapshot = BookContextSnapshot(bookId: UUID())
        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())
        _ = try await fetcher.fetch(language: nil, bookContext: snapshot)

        let json = try captured.json()
        #expect(json["language"] == nil)
        #expect(json["book_id"] != nil)
    }
}

// MARK: - Capture box + URLProtocol stub

/// Mutable capture box used by the URLProtocol stub to surface the request
/// the fetcher actually emitted. Lock-free because the .serialized suite
/// guarantees one test at a time on this box.
final class BodyCaptureBox: @unchecked Sendable {
    var body: Data?
    var method: String?
    var urlString: String?

    func json() throws -> [String: Any] {
        guard let body else { return [:] }
        let any = try JSONSerialization.jsonObject(with: body)
        return (any as? [String: Any]) ?? [:]
    }
}

/// Minimal in-process URLProtocol that captures the outgoing request for
/// body-shape assertions.
final class BookContextStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    static func reset() {
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
