import Foundation
import Testing
import RishiCore
import RishiAPI
@testable import RishiAuth

@Suite(
    "GoogleSignInCoordinator — happy + cancel + missing-token + malformed + URL helpers",
    .serialized // GoogleStubURLProtocol uses static state; run tests in serial.
)
struct GoogleOAuthFlowTests {

    // MARK: - Mock presenter

    actor MockGoogleWebAuthPresenter: GoogleWebAuthPresenter {
        private let result: Result<URL, Error>
        private(set) var lastURL: URL?
        private(set) var lastScheme: String?
        private(set) var callCount = 0

        init(result: Result<URL, Error>) {
            self.result = result
        }

        nonisolated func presentWebAuth(url: URL, callbackScheme: String) async throws -> URL {
            try await record(url: url, scheme: callbackScheme)
        }

        private func record(url: URL, scheme: String) throws -> URL {
            lastURL = url
            lastScheme = scheme
            callCount += 1
            return try result.get()
        }
    }

    // MARK: - Stub URL protocol (own copy to keep parallel-safe w/ SIWA tests)

    final class GoogleStubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestLog: [URLRequest] = []
        nonisolated(unsafe) static var bodyLog: [Data] = []
        nonisolated(unsafe) static var responseJSON: String = ""
        nonisolated(unsafe) static var responseStatus: Int = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            GoogleStubURLProtocol.requestLog.append(request)
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    collected.append(buffer, count: read)
                }
                GoogleStubURLProtocol.bodyLog.append(collected)
            } else if let body = request.httpBody {
                GoogleStubURLProtocol.bodyLog.append(body)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: GoogleStubURLProtocol.responseStatus,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(GoogleStubURLProtocol.responseJSON.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func reset() {
            requestLog = []
            bodyLog = []
            responseJSON = ""
            responseStatus = 200
        }
    }

    static func makeWorkerClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://api.fidexa.org")!,
            session: session,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    // MARK: - Tests

    @Test func happyPathProducesSessionWithProviderGoogle() async throws {
        // Plan 15-02: Session.userId is `String` (Better Auth user.id).
        GoogleStubURLProtocol.reset()
        let userId = UUID().uuidString
        GoogleStubURLProtocol.responseJSON = """
        {"session_token":"goog-tok","user_id":"\(userId)","email":"u@gmail.com"}
        """
        let callback = URL(string: "rishi://auth/callback?token=goog-id-xyz")!
        let presenter = MockGoogleWebAuthPresenter(result: .success(callback))
        let coordinator = GoogleSignInCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )

        let session = try await coordinator.signIn()

        #expect(session.provider == .google)
        #expect(session.token == "goog-tok")
        #expect(session.userId == userId)
        #expect(session.email == "u@gmail.com")

        // Presenter must be asked with the right URL + scheme
        let lastURL = await presenter.lastURL
        let lastScheme = await presenter.lastScheme
        #expect(lastScheme == "rishi")
        #expect(lastURL?.absoluteString.contains("provider=google") == true)
        #expect(lastURL?.absoluteString.contains("device=ios") == true)

        // Body sent to /api/auth/google contains id_token=goog-id-xyz
        #expect(GoogleStubURLProtocol.requestLog.count == 1)
        #expect(GoogleStubURLProtocol.requestLog.first?.url?.path == "/api/auth/google")
        let bodyString = String(data: GoogleStubURLProtocol.bodyLog[0], encoding: .utf8) ?? ""
        #expect(bodyString.contains("goog-id-xyz"))
    }

    @Test func cancellationThrowsAndDoesNotHitWorker() async throws {
        GoogleStubURLProtocol.reset()
        let presenter = MockGoogleWebAuthPresenter(result: .failure(RishiError.cancelled))
        let coordinator = GoogleSignInCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )
        do {
            _ = try await coordinator.signIn()
            Issue.record("Expected RishiError.cancelled")
        } catch let error as RishiError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
        }
        #expect(GoogleStubURLProtocol.requestLog.isEmpty)
    }

    @Test func missingTokenInCallbackThrowsAndDoesNotHitWorker() async throws {
        GoogleStubURLProtocol.reset()
        let callback = URL(string: "rishi://auth/callback?other=foo")!
        let presenter = MockGoogleWebAuthPresenter(result: .success(callback))
        let coordinator = GoogleSignInCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )

        do {
            _ = try await coordinator.signIn()
            Issue.record("Expected RishiError.network missing-token")
        } catch let error as RishiError {
            guard case .network(let code, _) = error, code == "google_oauth_missing_token" else {
                Issue.record("Expected .network(code: google_oauth_missing_token), got \(error)")
                return
            }
        }
        #expect(GoogleStubURLProtocol.requestLog.isEmpty)
    }

    @Test func emptyTokenValueIsForwardedToWorker() async throws {
        // Design decision: coordinator does NOT special-case empty strings; the
        // worker is the source of truth for what constitutes an invalid token.
        GoogleStubURLProtocol.reset()
        GoogleStubURLProtocol.responseStatus = 400
        GoogleStubURLProtocol.responseJSON = """
        {"error":{"code":"google_invalid_token","message":"empty"}}
        """
        let callback = URL(string: "rishi://auth/callback?token=")!
        let presenter = MockGoogleWebAuthPresenter(result: .success(callback))
        let coordinator = GoogleSignInCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )

        do {
            _ = try await coordinator.signIn()
            Issue.record("Expected worker 400 to throw")
        } catch {
            // Any error is fine here; the assertion is that the worker WAS called.
        }
        #expect(GoogleStubURLProtocol.requestLog.count >= 1)
    }

    @Test func buildStartURLAppendsQueryParams() {
        let a = GoogleSignInCoordinator.buildStartURL(base: URL(string: "https://api.fidexa.org")!)
        let b = GoogleSignInCoordinator.buildStartURL(base: URL(string: "https://api.fidexa.org/")!)
        for url in [a, b] {
            let s = url.absoluteString
            #expect(s.contains("/desktop/start"))
            #expect(s.contains("provider=google"))
            #expect(s.contains("device=ios"))
        }
    }

    @Test func parseCallbackTokenReturnsTokenOrNil() {
        let ok = URL(string: "rishi://auth/callback?token=abc&state=xyz")!
        #expect(GoogleSignInCoordinator.parseCallbackToken(ok) == "abc")

        let noToken = URL(string: "rishi://auth/callback?state=xyz")!
        #expect(GoogleSignInCoordinator.parseCallbackToken(noToken) == nil)

        let differentScheme = URL(string: "https://example.com/?token=abc")!
        #expect(GoogleSignInCoordinator.parseCallbackToken(differentScheme) == "abc")
        // (Scheme validation is intentionally NOT in the parser — the OS-level
        // ASWebAuthenticationSession enforces the scheme match.)
    }
}
