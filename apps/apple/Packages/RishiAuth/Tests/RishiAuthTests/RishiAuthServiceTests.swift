import Foundation
import Testing
import RishiCore
import RishiAPI
@testable import RishiAuth

@Suite("RishiAuthService — end-to-end with mock drivers", .serialized)
struct RishiAuthServiceTests {

    // MARK: - Mocks

    actor MockAppleDriver: AppleSignInDriver {
        let result: Result<Session, Error>
        private(set) var callCount = 0

        init(result: Result<Session, Error>) { self.result = result }

        func signIn() async throws -> Session {
            callCount += 1
            return try result.get()
        }
    }

    actor MockGoogleDriver: GoogleSignInDriver {
        let result: Result<Session, Error>
        private(set) var callCount = 0

        init(result: Result<Session, Error>) { self.result = result }

        func signIn() async throws -> Session {
            callCount += 1
            return try result.get()
        }
    }

    // MARK: - StubURLProtocol (private to this suite; static state guarded by .serialized)

    final class ServiceStubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Route { let status: Int; let body: String }

        nonisolated(unsafe) static var routes: [String: Route] = [:]
        nonisolated(unsafe) static var requestLog: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            ServiceStubURLProtocol.requestLog.append(request)
            let path = request.url?.path ?? ""
            let route = ServiceStubURLProtocol.routes[path] ?? Route(status: 404, body: "{}")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: route.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(route.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset() {
            routes = [:]
            requestLog = []
        }
    }

    // MARK: - Helpers

    static func makeWorkerClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServiceStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://api.fidexa.org")!,
            session: session,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    static func appleSession(token: String = "siwa-tok") -> Session {
        Session(
            token: token,
            userId: UUID(),
            email: "u@example.com",
            provider: .apple,
            issuedAt: Date(),
            expiresAt: nil
        )
    }

    static func googleSession(token: String = "goog-tok") -> Session {
        Session(
            token: token,
            userId: UUID(),
            email: "u@gmail.com",
            provider: .google,
            issuedAt: Date(),
            expiresAt: nil
        )
    }

    // MARK: - Tests

    @Test func signInWithApplePersistsSessionAndExposesCurrentUser() async throws {
        ServiceStubURLProtocol.reset()
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let session = Self.appleSession()
        let service = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .success(session)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychain,
            workerClient: Self.makeWorkerClient()
        )

        let user = try await service.signInWithApple()
        #expect(user.id == session.userId)
        #expect(user.email == "u@example.com")

        let loaded = try await keychain.load()
        #expect(loaded?.token == session.token)
        #expect(loaded?.provider == .apple)

        let current = await service.currentUser
        #expect(current?.id == session.userId)
    }

    @Test func signInWithGooglePersistsSessionAndExposesCurrentUser() async throws {
        ServiceStubURLProtocol.reset()
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let session = Self.googleSession()
        let service = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .failure(RishiError.cancelled)),
            googleDriver: MockGoogleDriver(result: .success(session)),
            keychain: keychain,
            workerClient: Self.makeWorkerClient()
        )

        let user = try await service.signInWithGoogle()
        #expect(user.email == "u@gmail.com")

        let loaded = try await keychain.load()
        #expect(loaded?.token == session.token)
        #expect(loaded?.provider == .google)
    }

    @Test func currentUserSurvivesFreshServiceInstance() async throws {
        ServiceStubURLProtocol.reset()
        let backend = InMemoryKeychainBackend()
        let keychainA = KeychainSessionStore(backend: backend)
        let session = Self.appleSession(token: "persisted-tok")

        let serviceA = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .success(session)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychainA,
            workerClient: Self.makeWorkerClient()
        )
        _ = try await serviceA.signInWithApple()

        // Simulate app relaunch: brand-new service over the same backend.
        let keychainB = KeychainSessionStore(backend: backend)
        let serviceB = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .failure(RishiError.cancelled)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychainB,
            workerClient: Self.makeWorkerClient()
        )
        let current = await serviceB.currentUser
        #expect(current?.id == session.userId)
    }

    @Test func signOutClearsKeychainEvenIfWorkerFails() async throws {
        ServiceStubURLProtocol.reset()
        ServiceStubURLProtocol.routes["/api/auth/sign-out"] =
            .init(status: 500, body: "{}")

        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let session = Self.appleSession()
        let service = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .success(session)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychain,
            workerClient: Self.makeWorkerClient()
        )
        _ = try await service.signInWithApple()
        try await service.signOut()

        let loaded = try await keychain.load()
        #expect(loaded == nil)
        let current = await service.currentUser
        #expect(current == nil)
    }

    @Test func deleteAccountHappyPathCallsWorkerAndClearsKeychain() async throws {
        ServiceStubURLProtocol.reset()
        ServiceStubURLProtocol.routes["/api/auth/delete-user"] =
            .init(status: 200, body: "{\"ok\":true}")

        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let session = Self.appleSession()
        let service = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .success(session)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychain,
            workerClient: Self.makeWorkerClient()
        )
        _ = try await service.signInWithApple()
        try await service.deleteAccount()

        let hitDelete = ServiceStubURLProtocol.requestLog
            .contains { $0.url?.path == "/api/auth/delete-user" }
        #expect(hitDelete, "deleteAccount must POST /api/auth/delete-user")

        let loaded = try await keychain.load()
        #expect(loaded == nil)
    }

    @Test func deleteAccountKeepsKeychainOnWorkerFailure() async throws {
        ServiceStubURLProtocol.reset()
        ServiceStubURLProtocol.routes["/api/auth/delete-user"] =
            .init(status: 500, body: "{}")

        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let session = Self.appleSession()
        let service = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .success(session)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychain,
            workerClient: Self.makeWorkerClient()
        )
        _ = try await service.signInWithApple()

        var threw = false
        do {
            try await service.deleteAccount()
        } catch {
            threw = true
        }
        #expect(threw, "deleteAccount must rethrow worker failure")

        // Keychain MUST persist so the UI can retry.
        let loaded = try await keychain.load()
        #expect(loaded != nil, "Keychain must persist when worker delete fails so user can retry")
    }

    @Test func tokenProviderReadsCurrentSessionToken() async throws {
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let provider = RishiAuthTokenProvider(keychain: keychain)

        #expect(await provider.token() == nil)

        let session = Self.appleSession(token: "live-tok")
        try await keychain.save(session)
        #expect(await provider.token() == "live-tok")

        try await keychain.delete()
        #expect(await provider.token() == nil)
    }

    @Test func currentUserSynthesisesPlaceholderEmailWhenSessionEmailNil() async throws {
        // PITFALLS Pitfall 10: SIWA may return nil email on 2nd sign-in.
        ServiceStubURLProtocol.reset()
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainSessionStore(backend: backend)
        let userId = UUID()
        let session = Session(
            token: "tok",
            userId: userId,
            email: nil,
            provider: .apple,
            issuedAt: Date(),
            expiresAt: nil
        )
        let service = RishiAuthService(
            siwaDriver: MockAppleDriver(result: .success(session)),
            googleDriver: MockGoogleDriver(result: .failure(RishiError.cancelled)),
            keychain: keychain,
            workerClient: Self.makeWorkerClient()
        )
        let user = try await service.signInWithApple()
        #expect(user.email == "apple+\(userId.uuidString).local")
        #expect(user.id == userId)
    }
}
