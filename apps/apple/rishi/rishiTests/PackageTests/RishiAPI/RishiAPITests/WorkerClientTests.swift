@testable import rishi
import Foundation
import Testing



@Suite("WorkerClient", .serialized)  // serialized because MockURLProtocol uses static state
struct WorkerClientTests {

    // MARK: - Helpers

    private struct PingResponse: Decodable, Equatable, Sendable {
        let ok: Bool
    }
    private struct PingEndpoint: WorkerEndpoint {
        typealias Response = PingResponse
        let method: HTTPMethod = .GET
        let path: String = "/ping"
    }
    private struct PostBody: Encodable, Sendable { let hello: String }
    private struct PostEndpoint: WorkerEndpointWithBody {
        typealias Response = PingResponse
        typealias Body = PostBody
        let method: HTTPMethod = .POST
        let path: String = "/post-thing"
        let body: PostBody
    }
    /// Bodyless POST (e.g. /api/auth/sign-out) — no `WorkerEndpointWithBody` conformance.
    private struct BodylessPostEndpoint: WorkerEndpoint {
        typealias Response = PingResponse
        let method: HTTPMethod = .POST
        let path: String = "/sign-out"
    }

    private func makeClient(
        token: String? = "test-token",
        devBypass: Bool = false,
        consented: Bool = false
    ) -> (WorkerClient, URL) {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let base = URL(string: "https://api.rishi.test")!
        let client = WorkerClient(
            baseURL: base,
            session: session,
            tokenProvider: StaticTokenProvider(token),
            dataUseConsentProvider: consented
                ? AlwaysAllowWorkerDataUseConsentProvider()
                : NoWorkerDataUseConsentProvider(),
            devBypassEnabled: devBypass
        )
        return (client, base)
    }

    private func ok() -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.rishi.test/ping")!,
                        statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.rishi.test/ping")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    // MARK: - Tests

    @Test func happyPath200DecodesResponse() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (self.ok(), Data(#"{"ok":true}"#.utf8))
        }
        let result = try await client.send(PingEndpoint())
        #expect(result == PingResponse(ok: true))
    }

    @Test func authorizationHeaderIsSet() async throws {
        let (client, _) = makeClient(token: "session-abc")
        MockURLProtocol.setHandler { _ in (self.ok(), Data(#"{"ok":true}"#.utf8)) }
        _ = try await client.send(PingEndpoint())
        let req = try #require(MockURLProtocol.recordedRequests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer session-abc")
    }

    @Test func nilTokenOmitsAuthorizationHeader() async throws {
        let (client, _) = makeClient(token: nil)
        MockURLProtocol.setHandler { _ in (self.ok(), Data(#"{"ok":true}"#.utf8)) }
        _ = try await client.send(PingEndpoint())
        let req = try #require(MockURLProtocol.recordedRequests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    #if DEBUG
    @Test func devBypassHeaderInDebug() async throws {
        let (client, _) = makeClient(devBypass: true)
        MockURLProtocol.setHandler { _ in (self.ok(), Data(#"{"ok":true}"#.utf8)) }
        _ = try await client.send(PingEndpoint())
        let req = try #require(MockURLProtocol.recordedRequests.first)
        #expect(req.value(forHTTPHeaderField: "X-Dev-Bypass") == "1")
    }
    #endif

    @Test func status401ThrowsUnauthenticated() async {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in (self.http(401), Data()) }
        do {
            _ = try await client.send(PingEndpoint())
            Issue.record("Expected throw")
        } catch RishiError.unauthenticated {
            // expected
        } catch {
            Issue.record("Expected .unauthenticated, got \(error)")
        }
    }

    @Test func status403DecodesEnvelope() async {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (self.http(403), Data(#"{"error":{"code":"forbidden","message":"Pro required"}}"#.utf8))
        }
        do {
            _ = try await client.send(PingEndpoint())
            Issue.record("expected throw")
        } catch let RishiError.network(code, message) {
            #expect(code == "forbidden")
            #expect(message == "Pro required")
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func sendDecodesCanonicalAllowanceResponse() async {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (
                self.http(402),
                Data(#"{"error":"Trial credits are exhausted","code":"INSUFFICIENT_ALLOWANCE","allowance_kind":"trial"}"#.utf8)
            )
        }

        do {
            _ = try await client.send(PingEndpoint())
            Issue.record("expected WorkerAllowanceError")
        } catch let error as WorkerAllowanceError {
            #expect(error == .trial(message: "Trial credits are exhausted"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func sendPreservesTypedAllowanceEvenIfWorkerStatusIs500() async {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (
                self.http(500),
                Data(#"{"error":"Trial credits are exhausted","code":"INSUFFICIENT_ALLOWANCE","allowance_kind":"trial"}"#.utf8)
            )
        }

        do {
            _ = try await client.send(PingEndpoint())
            Issue.record("expected WorkerAllowanceError")
        } catch let error as WorkerAllowanceError {
            #expect(error == .trial(message: "Trial credits are exhausted"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func downloadDecodesCanonicalAllowanceResponse() async {
        let (client, _) = makeClient(consented: true)
        MockURLProtocol.setHandler { _ in
            (
                self.http(402),
                Data(#"{"error":"Trial credits are exhausted","code":"INSUFFICIENT_ALLOWANCE","allowance_kind":"trial"}"#.utf8)
            )
        }

        do {
            _ = try await client.downloadData(
                SpeechStreamEndpoint(body: .init(text: "hello", voice: "alloy"))
            )
            Issue.record("expected WorkerAllowanceError")
        } catch let error as WorkerAllowanceError {
            #expect(error == .trial(message: "Trial credits are exhausted"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func status4xxDoesNotRetry() async {
        let (client, _) = makeClient()
        let counter = Counter()
        MockURLProtocol.setHandler { _ in
            counter.increment()
            return (self.http(400), Data())
        }
        do { _ = try await client.send(PingEndpoint()) } catch { /* ignore */ }
        #expect(counter.value == 1)
    }

    @Test func transientNetworkErrorRetriesUpToThreeAttempts() async {
        let (client, _) = makeClient()
        let counter = Counter()
        MockURLProtocol.setHandler { _ in
            counter.increment()
            throw URLError(.timedOut)
        }
        do { _ = try await client.send(PingEndpoint()) } catch { /* expected */ }
        #expect(counter.value == 3)
    }

    @Test func fivexxRetriesThenSucceeds() async throws {
        let (client, _) = makeClient()
        let counter = Counter()
        MockURLProtocol.setHandler { _ in
            counter.increment()
            if counter.value < 3 {
                return (self.http(503), Data())
            }
            return (self.ok(), Data(#"{"ok":true}"#.utf8))
        }
        let result = try await client.send(PingEndpoint())
        #expect(result.ok == true)
        #expect(counter.value == 3)
    }

    @Test func postBodyIsEncodedAsJSON() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in (self.ok(), Data(#"{"ok":true}"#.utf8)) }
        _ = try await client.send(PostEndpoint(body: PostBody(hello: "world")))
        let req = try #require(MockURLProtocol.recordedRequests.first)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.httpMethod == "POST")
        // URLProtocol can stash the body on either httpBody OR httpBodyStream.
        if let body = req.httpBody {
            let str = String(data: body, encoding: .utf8) ?? ""
            #expect(str.contains("\"hello\""))
        } else if let stream = req.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 1024)
            var collected = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                collected.append(buf, count: n)
            }
            stream.close()
            let str = String(data: collected, encoding: .utf8) ?? ""
            #expect(str.contains("\"hello\""))
        }
    }

    @Test func endpointPathQueryBecomesRealQueryNotPercentEncoded() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in (self.ok(), Data(#"{"changes":[]}"#.utf8)) }
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await client.send(SyncChangesEndpoint(since: since))
        let req = try #require(MockURLProtocol.recordedRequests.first)
        let url = try #require(req.url)
        // The '?' must be a real query separator, never percent-encoded into the path.
        #expect(!url.absoluteString.contains("%3F"))
        #expect(url.path == "/api/sync/changes")
        #expect(url.query?.hasPrefix("since=") == true)
    }

    // MARK: - Bearer-only / Content-Type request-building

    @Test func bodylessPostStillSetsJSONContentType() async throws {
        let (client, _) = makeClient()
        let req = try await client.buildRequest(for: BodylessPostEndpoint())
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func postRequestDisablesCookieHandling() async throws {
        let (client, _) = makeClient()
        let req = try await client.buildRequest(for: BodylessPostEndpoint())
        #expect(req.httpShouldHandleCookies == false)
    }

    @Test func getRequestHasNoContentTypeAndDisablesCookies() async throws {
        let (client, _) = makeClient()
        let req = try await client.buildRequest(for: PingEndpoint())
        #expect(req.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(req.httpShouldHandleCookies == false)
    }

    @Test func bodiedPostKeepsContentTypeAndBody() async throws {
        let (client, _) = makeClient()
        let req = try await client.buildRequest(for: PostEndpoint(body: PostBody(hello: "world")))
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.httpBody != nil)
    }

    @Test func decodeFailureThrowsRishiErrorDecoding() async {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in (self.ok(), Data("not json".utf8)) }
        do {
            _ = try await client.send(PingEndpoint())
            Issue.record("expected throw")
        } catch let RishiError.decoding(msg) {
            #expect(msg.contains("PingResponse") || msg.contains("decode"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func streamingTypedAllowanceErrorWinsEvenIfWorkerStatusIs500() async throws {
        let (client, _) = makeClient(consented: true)
        let message = "Trial credits are exhausted"
        MockURLProtocol.setHandler { _ in
            (
                self.http(500),
                Data(#"{"error":"Trial credits are exhausted","code":"INSUFFICIENT_ALLOWANCE","allowance_kind":"trial"}"#.utf8)
            )
        }

        let stream = await client.stream(
            SpeechStreamEndpoint(body: .init(text: "hello", voice: "alloy"))
        )
        do {
            for try await _ in stream { }
            Issue.record("expected WorkerAllowanceError")
        } catch let error as WorkerAllowanceError {
            #expect(error == .trial(message: message))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func streamingTypedAllowanceErrorDecodesCanonical402Response() async throws {
        let (client, _) = makeClient(consented: true)
        let message = "Trial credits are exhausted"
        MockURLProtocol.setHandler { _ in
            (
                self.http(402),
                Data(#"{"error":"Trial credits are exhausted","code":"INSUFFICIENT_ALLOWANCE","allowance_kind":"trial"}"#.utf8)
            )
        }

        let stream = await client.stream(
            SpeechStreamEndpoint(body: .init(text: "hello", voice: "alloy"))
        )
        do {
            for try await _ in stream { }
            Issue.record("expected WorkerAllowanceError")
        } catch let error as WorkerAllowanceError {
            #expect(error == .trial(message: message))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

/// Thread-safe counter so `@Sendable` test handlers can mutate state.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
