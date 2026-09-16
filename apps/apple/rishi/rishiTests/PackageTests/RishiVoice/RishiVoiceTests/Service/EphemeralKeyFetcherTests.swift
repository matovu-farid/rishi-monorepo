@testable import rishi
import Testing
import Foundation




/// Tests for `EphemeralKeyFetcher` — the actor that wraps
/// `WorkerClient.send(RealtimeClientSecretsEndpoint)` and surfaces a
/// Sendable `EphemeralKey` value.
///
/// `.serialized` because `EphemeralKeyStubURLProtocol` keeps a `nonisolated(unsafe)`
/// static responder; concurrent tests would race it.
@Suite("EphemeralKeyFetcher", .serialized)
struct EphemeralKeyFetcherTests {

    // MARK: - Helpers

    private func makeWorkerClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EphemeralKeyStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://api.fidexa.org")!,
            session: session,
            tokenProvider: StaticTokenProvider("stub-token")
        )
    }

    // MARK: - Tests

    @Test("Returns secret + sessionId on 200 (POST + bare path; Phase 25)")
    func returnsSecretOn200() async throws {
        EphemeralKeyStubURLProtocol.reset()
        EphemeralKeyStubURLProtocol.responder = { req in
            // Phase 25 (Plan 25-08) moved this endpoint from GET to POST.
            // The optional `language` argument lives in the JSON body now —
            // body-shape assertions live in
            // `EphemeralKeyFetcherBookContextTests`. Here we only pin that
            // the path is bare (no `?language=` query) and the method is POST.
            let abs = req.url?.absoluteString ?? ""
            #expect(abs.contains("/api/realtime/client_secrets"))
            #expect(abs.contains("language=") == false)
            #expect(req.httpMethod == "POST")
            let body = #"{"client_secret":"sk-ephemeral-xyz","session_id":"sess-123"}"#
            return (200, Data(body.utf8))
        }
        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())

        let key = try await fetcher.fetch(language: "en")
        #expect(key.secret == "sk-ephemeral-xyz")
        #expect(key.sessionId == "sess-123")
    }

    @Test("nil language: POST path stays bare; body omits language (Phase 25)")
    func nilLanguageOmitsQuery() async throws {
        EphemeralKeyStubURLProtocol.reset()
        EphemeralKeyStubURLProtocol.responder = { req in
            let abs = req.url?.absoluteString ?? ""
            #expect(abs.contains("/api/realtime/client_secrets"))
            #expect(abs.contains("language=") == false)
            #expect(req.httpMethod == "POST")
            let body = #"{"client_secret":"x","session_id":"y"}"#
            return (200, Data(body.utf8))
        }
        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())
        let key = try await fetcher.fetch()
        #expect(key.secret == "x")
        #expect(key.sessionId == "y")
    }

    @Test("Rethrows RishiError.unauthenticated on 401")
    func rethrowsOn401() async {
        EphemeralKeyStubURLProtocol.reset()
        EphemeralKeyStubURLProtocol.responder = { _ in
            let body = #"{"error":{"code":"unauthenticated","message":"sign in required"}}"#
            return (401, Data(body.utf8))
        }
        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())

        await #expect(throws: RishiError.self) {
            _ = try await fetcher.fetch(language: nil)
        }
    }

    @Test("Rethrows RishiError.network on 4xx (non-401)")
    func rethrowsOn4xx() async {
        EphemeralKeyStubURLProtocol.reset()
        EphemeralKeyStubURLProtocol.responder = { _ in
            let body = #"{"error":{"code":"bad_request","message":"missing param"}}"#
            return (400, Data(body.utf8))
        }
        let fetcher = EphemeralKeyFetcher(workerClient: makeWorkerClient())

        do {
            _ = try await fetcher.fetch(language: nil)
            Issue.record("Expected throw on 400")
        } catch let error as RishiError {
            switch error {
            case .network(let code, _):
                #expect(code == "bad_request")
            default:
                Issue.record("Expected RishiError.network, got \(error)")
            }
        } catch {
            Issue.record("Expected RishiError, got \(error)")
        }
    }
}

// MARK: - URLProtocol stub

/// Minimal in-process URLProtocol so tests don't reach the network. Mirrors the
/// pattern used by `RishiAPITests/MockURLProtocol.swift` but lives in the
/// RishiVoice test target so we don't have a cross-package test dep.
final class EphemeralKeyStubURLProtocol: URLProtocol, @unchecked Sendable {
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
