@testable import rishi
import Foundation
import Testing




/// `.serialized` because every test in this suite shares the suite-local
/// ``StubURLProtocol`` static state — Swift Testing's default parallel runner
/// would otherwise let two tests race over `responseJSON`/`requestLog` and
/// flake catastrophically. Each test is fast (~2ms) so the serialization
/// cost is negligible.
///
/// Plan 15-06 rewrite: the coordinator now POSTs to Better Auth's standard
/// `/api/auth/sign-in/social` endpoint with the `{ provider, idToken: { token,
/// nonce, user? }, disableRedirect }` envelope verified against the installed
/// `@better-auth/core@1.6.10` source. The identity token is sent as the raw
/// JWT string (UTF-8 of the bytes Apple hands us), NOT base64-re-encoded.
@Suite("SignInWithAppleCoordinator — Better Auth /api/auth/sign-in/social", .serialized)
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

    /// A synthetic JWT in the same UTF-8-of-ASCII shape Apple actually returns
    /// in `ASAuthorizationAppleIDCredential.identityToken`. The header decodes
    /// as `{"alg":"ES256","kid":"test"}` so callers can verify the body is the
    /// raw JWT string (not base64-re-wrapped).
    static let syntheticJWT: String =
        "eyJhbGciOiJFUzI1NiIsImtpZCI6InRlc3QifQ" +
        ".eyJzdWIiOiIwMDEyMzQuYWJjZGVmLjU2NzgifQ" +
        ".signature"

    /// 64-hex SHA-256-shaped digest used in tests. Real `Nonce.generate()` will
    /// be exercised by `NonceTests`; here we only need a deterministic value to
    /// thread through both sides of the contract.
    static let fixedNonceHex: String =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// Sample successful Better Auth `/api/auth/sign-in/social` response body.
    /// `user.id` is an Apple `sub`-shaped String (never UUID).
    static func successResponseJSON(
        token: String = "tok-happy",
        userId: String = "001234.abcdef.5678",
        email: String? = "u@example.com"
    ) -> String {
        let emailField = email.map { "\"\($0)\"" } ?? "null"
        return """
        {"redirect":false,"token":"\(token)","user":{"id":"\(userId)","email":\(emailField),"name":"Jane Appleseed","emailVerified":true,"image":null}}
        """
    }

    static func credential(
        identityTokenData: Data? = nil,
        authorizationCode: Data = Data("apple-auth-code".utf8),
        user: String = "001234.abcdef.5678",
        fullName: SiwaName? = SiwaName(firstName: "Jane", lastName: "Appleseed"),
        email: String? = "u@example.com",
        nonceHex: String = fixedNonceHex
    ) -> SiwaCredential {
        SiwaCredential(
            identityTokenData: identityTokenData ?? Data(syntheticJWT.utf8),
            authorizationCode: authorizationCode,
            user: user,
            fullName: fullName,
            email: email,
            nonceHex: nonceHex
        )
    }

    // MARK: - Decodable mirror of the body
    //
    // The production `SignInSocialEndpoint.Body` is Encodable-only (one-way on
    // the wire), so tests use a parallel Decodable mirror to inspect what the
    // coordinator emitted without polluting the production type.

    struct DecodedBody: Decodable, Equatable {
        let provider: String
        let idToken: DecodedIdToken
        let disableRedirect: Bool

        struct DecodedIdToken: Decodable, Equatable {
            let token: String
            let nonce: String
            let user: DecodedUser?

            struct DecodedUser: Decodable, Equatable {
                let name: DecodedName?
                let email: String?

                struct DecodedName: Decodable, Equatable {
                    let firstName: String?
                    let lastName: String?
                }
            }
        }
    }

    /// Decode the captured outbound body via a Decodable mirror that matches
    /// the production `SignInSocialEndpoint.Body` shape. The `user` field on
    /// the encoded payload may be absent — JSONDecoder treats missing keys for
    /// Optional types as `nil`.
    static func decodeBody(_ data: Data) throws -> DecodedBody {
        try JSONDecoder().decode(DecodedBody.self, from: data)
    }

    // MARK: - Tests

    @Test func happyPathProducesSessionWithProviderApple() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON(
            token: "tok-happy",
            userId: "001234.abcdef.5678",
            email: "u@example.com"
        ))
        let presenter = MockSiwaPresenter(result: .success(Self.credential()))
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: presenter
        )

        let session = try await coordinator.signIn()

        #expect(session.token == "tok-happy")
        #expect(session.userId == "001234.abcdef.5678")
        #expect(session.email == "u@example.com")
    }

    @Test func postsToSignInSocialPath() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON())
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(Self.credential()))
        )

        _ = try await coordinator.signIn()

        let requests = StubURLProtocol.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/api/auth/sign-in/social")
        #expect(requests.first?.httpMethod == "POST")
    }

    @Test func privateRelayEmailPassesThroughUnchanged() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON(
            email: "abc123@privaterelay.appleid.com"
        ))
        let cred = Self.credential(email: "abc123@privaterelay.appleid.com")
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        let session = try await coordinator.signIn()
        #expect(session.email == "abc123@privaterelay.appleid.com")

        let body = try Self.decodeBody(StubURLProtocol.recordedBodies()[0])
        #expect(body.idToken.user?.email == "abc123@privaterelay.appleid.com")
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

    @Test func firstSignInForwardsUserNameAndEmail() async throws {
        // PITFALLS Pitfall 8: first-sign-in MUST forward Apple's disclosed
        // fullName + email as a structured `idToken.user` block so Better
        // Auth's `getUserInfo` can populate user.name (apple.mjs:77). Without
        // this, the user row is created with `name: ""`.
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON())
        let cred = Self.credential(
            fullName: SiwaName(firstName: "Jane", lastName: "Appleseed"),
            email: "u@example.com"
        )
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        _ = try await coordinator.signIn()

        let body = try Self.decodeBody(StubURLProtocol.recordedBodies()[0])
        #expect(body.provider == "apple")
        #expect(body.disableRedirect == true)
        #expect(body.idToken.user != nil)
        #expect(body.idToken.user?.name?.firstName == "Jane")
        #expect(body.idToken.user?.name?.lastName == "Appleseed")
        #expect(body.idToken.user?.email == "u@example.com")
    }

    @Test func subsequentSignInOmitsUserBlock() async throws {
        // PITFALLS Pitfall 10: Apple returns nil fullName + nil email on
        // re-authentication. The coordinator MUST omit `idToken.user`
        // entirely — sending an empty-string user block would clobber the
        // user.name Better Auth already has stored.
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON(
            userId: "001234.abcdef.5678",
            email: nil
        ))
        let cred = Self.credential(fullName: nil, email: nil)
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        let session = try await coordinator.signIn()
        #expect(session.email == nil)
        #expect(session.userId == "001234.abcdef.5678")

        // The encoded body must NOT contain the "user" key — assert via raw
        // JSON inspection because Optional fields encode to JSON null when the
        // encoder uses the default strategy, but the coordinator uses
        // .deferredToData with explicit omission.
        let rawBody = String(data: StubURLProtocol.recordedBodies()[0], encoding: .utf8) ?? ""
        #expect(!rawBody.contains("\"user\""), "Re-sign-in must omit idToken.user, got: \(rawBody)")

        // Defensive: also confirm the typed decode sees user as nil.
        let body = try Self.decodeBody(StubURLProtocol.recordedBodies()[0])
        #expect(body.idToken.user == nil)
    }

    @Test func identityTokenSentAsRawJWTNotBase64() async throws {
        // PITFALLS Pitfall 2: `ASAuthorizationAppleIDCredential.identityToken`
        // is `Data?` but the bytes ARE the UTF-8 of the JWT string. The legacy
        // coordinator base64-re-wrapped them; Better Auth's `decodeJwt(token)`
        // (apple.mjs:74) needs the raw JWT string. The body's idToken.token
        // MUST begin with "eyJ" (standard JWT header prefix base64url-encoded
        // ONCE, by Apple) and decode as the same string we handed in.
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON())
        let cred = Self.credential(identityTokenData: Data(Self.syntheticJWT.utf8))
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        _ = try await coordinator.signIn()

        let body = try Self.decodeBody(StubURLProtocol.recordedBodies()[0])
        #expect(body.idToken.token == Self.syntheticJWT)
        #expect(body.idToken.token.hasPrefix("eyJ"))
        // Verify the header section decodes as a real JSON object — this
        // guards against the body being a base64 envelope around the JWT.
        let segments = body.idToken.token.split(separator: ".")
        #expect(segments.count == 3, "JWT must have header.payload.signature")
        let headerSegment = String(segments[0])
        // Apply base64url -> base64 padding so Foundation's decoder accepts it.
        let padded = headerSegment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((headerSegment.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        let headerData = Data(base64Encoded: padded) ?? Data()
        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256",
                "Header must contain alg — raw JWT, not base64 envelope")
    }

    @Test func nonceIsBoundToBothApplePromptAndBetterAuthBody() async throws {
        // PITFALLS Pitfall 1: the nonce must be the SAME hex string on both
        // sides — the value we hand to `ASAuthorizationAppleIDRequest.nonce`
        // (Apple stores it verbatim in the JWT `nonce` claim) and the value we
        // POST as `idToken.nonce` (Better Auth compares jwtClaims.nonce ===
        // body.nonce at apple.mjs:58). In production the SystemSiwaPresenter
        // generates `let (raw, hex) = Nonce.generate()` and hands the SAME
        // `hex` to Apple AND back to the coordinator on the credential. Here
        // we simulate that contract by asserting that whatever the presenter
        // exposes as `credential.nonceHex` appears verbatim in the posted
        // idToken.nonce field.
        StubURLProtocol.reset()
        StubURLProtocol.setResponse(json: Self.successResponseJSON())
        let presenterNonce = Self.fixedNonceHex
        let cred = Self.credential(nonceHex: presenterNonce)
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(cred))
        )

        _ = try await coordinator.signIn()

        let body = try Self.decodeBody(StubURLProtocol.recordedBodies()[0])
        #expect(body.idToken.nonce == presenterNonce,
                "idToken.nonce must equal exactly what was bound to AppleIDRequest.nonce")
        #expect(body.idToken.nonce.count == 64)
    }

    @Test func sessionUserIdCarriesAppleSubVerbatim() async throws {
        // Plan 15-02 cascade: Session.userId is now `String`. The
        // coordinator passes response.user.id straight through with no UUID
        // conversion. Apple subs look like "001234.abcdef.1234" and are NOT
        // UUID-shaped.
        StubURLProtocol.reset()
        let appleSub = "001999.deadbeef.0000"
        StubURLProtocol.setResponse(json: Self.successResponseJSON(
            userId: appleSub,
            email: "x@y.z"
        ))
        let coordinator = SignInWithAppleCoordinator(
            workerClient: Self.makeWorkerClient(),
            presenter: MockSiwaPresenter(result: .success(Self.credential()))
        )

        let session = try await coordinator.signIn()
        #expect(session.userId == appleSub)
    }
}
