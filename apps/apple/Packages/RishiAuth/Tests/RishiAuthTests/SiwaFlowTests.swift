import Foundation
import Testing
import RishiCore
import RishiAPI
@testable import RishiAuth

/// `.serialized` because every test in this suite shares the suite-local
/// ``StubURLProtocol`` static state — Swift Testing's default parallel runner
/// would otherwise let two tests race over `responseJSON`/`requestLog` and
/// flake catastrophically. Each test is fast (~2ms) so the serialization
/// cost is negligible.
@Suite("SignInWithAppleCoordinator — happy + cancel + private-relay + missing-email", .serialized)
struct SiwaFlowTests {

    // MARK: - Mock presenter

    /// Actor-based mock so a single concurrency primitive owns both call count
    /// and the stashed result. The method itself is `nonisolated` to satisfy
    /// the `SiwaPresenter` protocol witness; it hops onto the actor via `await`
    /// to read its state. Tracking call count this way also lets the test
    /// assert that the presenter was (or wasn't) invoked.
    actor MockSiwaPresenter: SiwaPresenter {
        private let result: Result<SiwaCredential, RishiError>
        private(set) var callCount = 0

        init(result: Result<SiwaCredential, RishiError>) {
            self.result = result
        }

        nonisolated func presentSignInRequest(scopes: Set<SiwaScope>) async throws -> SiwaCredential {
            try await yieldResult()
        }

        private func yieldResult() throws -> SiwaCredential {
            callCount += 1
            return try result.get()
        }
    }

    // MARK: - Stub URL protocol (suite-local to dodge shared-static race)

    /// Each test class ships its own StubURLProtocol so Swift Testing's parallel
    /// test runner can't race over a shared `static var`. The `nonisolated(unsafe)`
    /// statics are guarded by an `NSLock` for the mutating accessors; tests use
    /// the static `reset()` / `setResponse(...)` API rather than touching them
    /// directly.
    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requestLog: [URLRequest] = []
        nonisolated(unsafe) static var bodyLog: [Data] = []
        nonisolated(unsafe) static var responseJSON: String = ""
        nonisolated(unsafe) static var responseStatus: Int = 200
        private static let lock = NSLock()

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            requestLog = []
            bodyLog = []
            responseJSON = ""
            responseStatus = 200
        }

        static func setResponse(json: String, status: Int = 200) {
            lock.lock(); defer { lock.unlock() }
            responseJSON = json
            responseStatus = status
        }

        static func recordedRequests() -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requestLog
        }

        static func recordedBodies() -> [Data] {
            lock.lock(); defer { lock.unlock() }
            return bodyLog
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            Self.requestLog.append(request)
            // URLProtocol strips httpBody from .data(for:) requests for chunked
            // bodies; recover via bodyStream if present, otherwise fall back to
            // the property.
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
                Self.bodyLog.append(collected)
            } else if let body = request.httpBody {
                Self.bodyLog.append(body)
            }
            let json = Self.responseJSON
            let status = Self.responseStatus
            Self.lock.unlock()

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    // MARK: - Helpers

    static func makeWorkerClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://api.fidexa.org")!,
            session: session,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    static func credential(
        identityToken: Data = Data("apple-id-token".utf8),
        authorizationCode: Data = Data("apple-auth-code".utf8),
        user: String = "001234.abcdef.5678",
        fullName: String? = "Jane Appleseed",
        email: String? = "u@example.com"
    ) -> SiwaCredential {
        SiwaCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            user: user,
            fullName: fullName,
            email: email
        )
    }

    // MARK: - Tests

    @Test func happyPathProducesSessionWithProviderApple() async throws {
        StubURLProtocol.reset()
        let userId = UUID()
        StubURLProtocol.setResponse(json: """
        {"session_token":"tok-happy","user_id":"\(userId.uuidString)","email":"u@example.com"}
        """)
        let presenter = MockSiwaPresenter(result: .success(Self.credential()))
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )

        let session = try await coordinator.signIn()

        #expect(session.token == "tok-happy")
        #expect(session.userId == userId)
        #expect(session.email == "u@example.com")
        #expect(session.provider == .apple)
    }

    @Test func privateRelayEmailPassesThroughUnchanged() async throws {
        StubURLProtocol.reset()
        let userId = UUID()
        StubURLProtocol.setResponse(json: """
        {"session_token":"tok-relay","user_id":"\(userId.uuidString)","email":"abc123@privaterelay.appleid.com"}
        """)
        let cred = Self.credential(email: "abc123@privaterelay.appleid.com")
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        let session = try await coordinator.signIn()
        #expect(session.email == "abc123@privaterelay.appleid.com")
        #expect(session.provider == .apple)
    }

    @Test func cancellationThrowsAndDoesNotHitWorker() async throws {
        StubURLProtocol.reset()
        let presenter = MockSiwaPresenter(result: .failure(RishiError.cancelled))
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )

        do {
            _ = try await coordinator.signIn()
            Issue.record("Expected signIn() to throw RishiError.cancelled")
        } catch let error as RishiError {
            guard case .cancelled = error else {
                Issue.record("Expected .cancelled, got \(error)")
                return
            }
        }
        #expect(StubURLProtocol.recordedRequests().isEmpty, "Worker MUST NOT be called on user cancel")
    }

    @Test func secondSignInWithNilEmailWorks() async throws {
        // PITFALLS.md Pitfall 10: Apple returns no email + no fullName on re-sign-in.
        StubURLProtocol.reset()
        let userId = UUID()
        StubURLProtocol.setResponse(json: """
        {"session_token":"tok-resign","user_id":"\(userId.uuidString)","email":null}
        """)
        let cred = Self.credential(fullName: nil, email: nil)
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        let session = try await coordinator.signIn()
        #expect(session.email == nil)
        #expect(session.userId == userId)
        #expect(session.provider == .apple)
    }

    @Test func requestBodyContainsBase64IdentityTokenAndUserSub() async throws {
        StubURLProtocol.reset()
        let userId = UUID()
        StubURLProtocol.setResponse(json: """
        {"session_token":"tok-body","user_id":"\(userId.uuidString)","email":"x@y.z"}
        """)
        let identityBytes = Data([0x01, 0x02, 0x03, 0x04])
        let cred = Self.credential(
            identityToken: identityBytes,
            user: "001999.deadbeef.0000"
        )
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )
        _ = try await coordinator.signIn()

        let requests = StubURLProtocol.recordedRequests()
        let bodies = StubURLProtocol.recordedBodies()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/api/auth/apple")
        #expect(bodies.count == 1)
        let bodyString = String(data: bodies[0], encoding: .utf8) ?? ""
        #expect(bodyString.contains(identityBytes.base64EncodedString()))
        #expect(bodyString.contains("001999.deadbeef.0000"))
    }
}
