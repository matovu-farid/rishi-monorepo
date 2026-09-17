import Foundation
import XCTest
@testable import RishiE2EHost

final class TestAccountClientTests: XCTestCase {
    func testPreflightAcceptsGateEnabledBodyValidationResponse() async throws {
        let transport = RecordingTransport(responses: [.status(400)])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport
        )

        try await client.preflight()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.path, "/test/sign-in")
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate-secret")
    }

    func testPreflightFailsWithoutTheProvisioningGate() async throws {
        let transport = RecordingTransport(responses: [.status(404)])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport
        )

        do {
            try await client.preflight()
            XCTFail("Expected unavailable provisioning route")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .provisioningUnavailable)
        }
    }

    func testPreflightFailsWhenTrialCreditLedgerIsUnavailable() async throws {
        let transport = RecordingTransport(responses: [.status(503)])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport
        )

        do {
            try await client.preflight()
            XCTFail("Expected unavailable credit provisioning")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .provisioningUnavailable)
        }
    }

    func testCreateUsesGatedSignInAndKeepsCredentialsInMemory() async throws {
        let transport = RecordingTransport(responses: [
            .json(["token": "bearer-secret", "userId": "server-user-1", "email": "owner-1@example.test"])
        ])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" }
        )

        let account = try await client.create(role: .owner)

        XCTAssertEqual(account.role, .owner)
        XCTAssertEqual(account.email, "rishi-e2e-fixed@example.test")
        XCTAssertEqual(account.userID, "server-user-1")
        XCTAssertEqual(account.bearerToken, "bearer-secret")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.path, "/test/sign-in")
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate-secret")
    }

    func testCreateAttemptsEmailTeardownWhenProvisioningTransportFails() async throws {
        let transport = FailingProvisioningTransport()
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" }
        )

        do {
            _ = try await client.create(role: .owner)
            XCTFail("Expected provisioning to fail")
        } catch is URLError {
            // The original error is retained when the compensating teardown
            // succeeds, while the temporary account is still removed.
        }

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].url?.path, "/test/sign-in")
        XCTAssertEqual(transport.requests[1].url?.lastPathComponent, "rishi-e2e-fixed@example.test")
        XCTAssertEqual(transport.requests[1].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate-secret")
    }

    func testCreateFailsClosedWhenCompensatingTeardownFails() async throws {
        let transport = FailingProvisioningTransport(cleanupStatus: 500)
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" }
        )

        do {
            _ = try await client.create(role: .participant)
            XCTFail("Expected provisioning to fail closed")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .provisioningCleanupFailed)
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testCreateDoesNotDeleteOnKnownHTTPFailure() async throws {
        let transport = RecordingTransport(responses: [.status(401)])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" }
        )

        do {
            _ = try await client.create(role: .owner)
            XCTFail("Expected provisioning HTTP failure")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .httpFailure(statusCode: 401))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCreateCompensatesAfterServerFailureThatMayFollowAccountCreation() async throws {
        let transport = RecordingTransport(responses: [.status(503), .status(200)])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" }
        )

        do {
            _ = try await client.create(role: .owner)
            XCTFail("Expected provisioning HTTP failure")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .httpFailure(statusCode: 503))
        }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/rishi-e2e-fixed@example.test")
        XCTAssertEqual(transport.requests[1].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate-secret")
    }

    func testDeleteUsesAuthenticatedUserDeletionRoute() async throws {
        let transport = RecordingTransport(responses: [.json(["ok": true])])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .participant, email: "invitee@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")

        try await client.delete(account)

        XCTAssertEqual(transport.requests[0].url?.path, "/api/user")
        XCTAssertEqual(transport.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
    }

    func testDeleteFailsIfTheCanonicalRouteDoesNotConfirmDeletion() async throws {
        let transport = RecordingTransport(responses: [.json(["deleted": true]), .status(500)])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")

        do {
            try await client.delete(account)
            XCTFail("Expected deletion cleanup failure")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .deletionCleanupFailed)
        }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/owner@example.test")
    }

    func testDeleteFallsBackToGatedEmailCleanupWhenBearerSessionFails() async throws {
        let transport = RecordingTransport(responses: [.status(401), .status(404)])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .participant, email: "invitee@example.test", password: "pw", userID: "u-1", bearerToken: "expired-token")

        try await client.delete(account)

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].url?.path, "/api/user")
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/invitee@example.test")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate")
    }

    func testDeleteRetriesTransientGatedCleanupFailure() async throws {
        let transport = RecordingTransport(responses: [.status(401), .status(503), .status(200)])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .participant, email: "invitee@example.test", password: "pw", userID: "u-1", bearerToken: "expired-token")

        try await client.delete(account)

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/invitee@example.test")
        XCTAssertEqual(transport.requests[2].url?.path, "/test/users/invitee@example.test")
    }

    func testRecoveryDeleteUsesOnlyConfiguredGeneratedEmailNamespace() async throws {
        let transport = RecordingTransport(responses: [.status(404)])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )

        try await client.deleteProvisionedAccount(email: "RISHI-E2E-recovery@example.test")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].url?.path, "/test/users/rishi-e2e-recovery@example.test")

        do {
            try await client.deleteProvisionedAccount(email: "someone-else@example.test")
            XCTFail("Expected recovery namespace validation to fail")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .invalidConfiguration("The recovery email is outside the configured test-account namespace."))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testVerifyDeletedAcceptsNotFoundAndRejectsRemainingData() async throws {
        let deletedTransport = RecordingTransport(responses: [.status(404)])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: deletedTransport
        )
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")
        try await client.verifyDeleted(account)

        let goneTransport = RecordingTransport(responses: [.status(410)])
        let goneClient = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: goneTransport
        )
        try await goneClient.verifyDeleted(account)

        let remainingTransport = RecordingTransport(responses: [.json(["user": true, "books": 0, "sessions": 0, "ledger": false])])
        let remainingClient = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: remainingTransport
        )
        do {
            try await remainingClient.verifyDeleted(account)
            XCTFail("Expected remaining account data to fail verification")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .deletionVerificationFoundResidue)
        }
    }

    func testWaitForBookUploadPollsUntilExpectedHashIsReady() async throws {
        let transport = RecordingTransport(responses: [
            .json(["changes": []]),
            .json(["changes": [[
                "kind": "book",
                "deleted": false,
                "payload": [
                    "file_hash": "expected-hash",
                    "file_r2_key": "books/owner/book.pdf",
                    "file_size": 123
                ]
            ]]])
        ])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")

        try await client.waitForBookUpload(account, expectedSHA256: "expected-hash", timeout: .seconds(2))

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].url?.path, "/api/sync/changes")
        XCTAssertEqual(URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "scope")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Rishi-Data-Use-Consent"), "2026-07-29")
    }

    func testWaitForBookUploadTimesOutWhenExpectedHashIsAbsent() async throws {
        let transport = RecordingTransport(responses: [.json(["changes": []])])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")

        do {
            try await client.waitForBookUpload(account, expectedSHA256: "missing-hash", timeout: .milliseconds(1))
            XCTFail("Expected book readiness timeout")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .bookUploadTimedOut)
        }
    }

    func testWaitForBookUploadRetriesTransientTransportFailure() async throws {
        let transport = TransientReadTransport()
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")

        try await client.waitForBookUpload(account, expectedSHA256: "expected-hash", timeout: .seconds(2))

        XCTAssertEqual(transport.requests.count, 2)
    }

    private final class RecordingTransport: TestAccountTransport, @unchecked Sendable {
        struct Response: Sendable {
            let statusCode: Int
            let data: Data

            static func json(_ object: [String: Any]) -> Response {
                Response(statusCode: 200, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            }

            static func status(_ statusCode: Int) -> Response { Response(statusCode: statusCode, data: Data()) }
        }

        private(set) var requests: [URLRequest] = []
        private var responses: [Response]

        init(responses: [Response]) { self.responses = responses }

        func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
            requests.append(request)
            let response = responses.removeFirst()
            return TestAccountHTTPResponse(statusCode: response.statusCode, data: response.data)
        }
    }

    private final class FailingProvisioningTransport: TestAccountTransport, @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        private let cleanupStatus: Int

        init(cleanupStatus: Int = 200) {
            self.cleanupStatus = cleanupStatus
        }

        func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
            requests.append(request)
            if requests.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            return TestAccountHTTPResponse(statusCode: cleanupStatus, data: Data())
        }
    }

    private final class TransientReadTransport: TestAccountTransport, @unchecked Sendable {
        private(set) var requests: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
            requests.append(request)
            if requests.count == 1 { throw URLError(.timedOut) }
            let data = try JSONSerialization.data(withJSONObject: ["changes": [[
                "kind": "book",
                "deleted": false,
                "payload": [
                    "file_hash": "expected-hash",
                    "file_r2_key": "books/owner/book.epub",
                    "file_size": 123
                ]
            ]]])
            return TestAccountHTTPResponse(statusCode: 200, data: data)
        }
    }
}
