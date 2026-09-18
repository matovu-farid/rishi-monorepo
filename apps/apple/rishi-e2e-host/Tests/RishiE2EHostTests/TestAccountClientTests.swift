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

    func testJournalRecordsGeneratedAddressBeforeProvisioningRequest() async throws {
        let recorder = LifecycleRecorder()
        let transport = SequencedInspectingTransport(steps: [
            .failure(URLError(.networkConnectionLost)) { request in
                XCTAssertEqual(request.url?.path, "/test/sign-in")
                XCTAssertEqual(recorder.events, ["pending:rishi-e2e-fixed@example.test:owner"])
            },
            .response(.status(200)) { request in
                XCTAssertEqual(request.url?.path, "/test/users/rishi-e2e-fixed@example.test")
            },
            .response(.json(["error": "user not found"], statusCode: 404)) { request in
                XCTAssertEqual(request.url?.path, "/test/users/rishi-e2e-fixed@example.test")
            },
        ])
        let client = TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate-secret",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" },
            lifecycleRecorder: recorder
        )

        do {
            _ = try await client.create(role: .owner)
            XCTFail("Expected lost provisioning response")
        } catch is URLError {}

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(recorder.events, [
            "pending:rishi-e2e-fixed@example.test:owner",
            "recoverable:rishi-e2e-fixed@example.test",
            "verified:rishi-e2e-fixed@example.test",
        ])
    }

    func testRecoveryRequiresSecondDeleteExactUserNotFoundJSON() async throws {
        let transport = RecordingTransport(responses: [
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = makeClient(transport: transport)

        try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test")

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["DELETE", "DELETE"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/test/users/rishi-e2e-recovery@example.test",
            "/test/users/rishi-e2e-recovery@example.test",
        ])
    }

    func testRecoveryRetriesEachTransientCleanupStatusThenStrictlyVerifiesAbsence() async throws {
        for statusCode in [502, 503, 504] {
            let recorder = LifecycleRecorder()
            let transport = RecordingTransport(responses: [
                .status(statusCode),
                .status(200),
                .json(["error": "user not found"], statusCode: 404),
            ])
            let client = makeClient(transport: transport, lifecycleRecorder: recorder)

            try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test")

            XCTAssertEqual(transport.requests.count, 3, "HTTP \(statusCode)")
            XCTAssertEqual(transport.requests.map(\.httpMethod), ["DELETE", "DELETE", "DELETE"], "HTTP \(statusCode)")
            XCTAssertEqual(transport.requests.map { $0.url?.path }, Array(repeating: "/test/users/rishi-e2e-recovery@example.test", count: 3), "HTTP \(statusCode)")
            XCTAssertEqual(recorder.events, ["verified:rishi-e2e-recovery@example.test"], "HTTP \(statusCode)")
        }
    }

    func testNormalDeleteRetriesTransientGatedCleanupThenVerifiesAbsence() async throws {
        let recorder = LifecycleRecorder()
        let transport = RecordingTransport(responses: [
            .status(401),
            .status(503),
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)
        let account = TestAccount(
            role: .owner,
            email: "rishi-e2e-owner@example.test",
            password: "pw",
            userID: "user-1",
            bearerToken: "expired"
        )

        try await client.delete(account)

        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/api/user",
            "/test/users/rishi-e2e-owner@example.test",
            "/test/users/rishi-e2e-owner@example.test",
            "/test/users/rishi-e2e-owner@example.test",
        ])
        XCTAssertEqual(recorder.events, ["verified:rishi-e2e-owner@example.test"])
    }

    func testCompensatingCleanupRetriesTransientDeleteThenVerifiesAbsence() async throws {
        let recorder = LifecycleRecorder()
        let transport = SequencedInspectingTransport(steps: [
            .failure(URLError(.networkConnectionLost)) { _ in },
            .response(.status(504)) { _ in },
            .response(.status(200)) { _ in },
            .response(.json(["error": "user not found"], statusCode: 404)) { _ in },
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        do {
            _ = try await client.create(role: .owner)
            XCTFail("Expected original provisioning transport error")
        } catch is URLError {}

        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(recorder.events, [
            "pending:rishi-e2e-fixed@example.test:owner",
            "recoverable:rishi-e2e-fixed@example.test",
            "verified:rishi-e2e-fixed@example.test",
        ])
    }

    func testTransientCleanupRetryExhaustionRetainsRecoverableJournalEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        let email = "rishi-e2e-owner@example.test"
        try journal.recordProvisioningAddress(email, role: .owner)
        try journal.recordProvisioningOutcome(.recoverable, email: email)
        let transport = RecordingTransport(responses: [.status(502), .status(502), .status(502)])
        let client = makeClient(transport: transport, lifecycleRecorder: journal)

        await XCTAssertThrowsErrorAsync(try await client.deleteProvisionedAccount(email: email))

        let data = try Data(contentsOf: journal.url)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let accounts = state?["accounts"] as? [[String: Any]]
        XCTAssertEqual(accounts?.map { $0["email"] as? String }, [email])
        XCTAssertEqual(accounts?.first?["outcome"] as? String, TestAccountProvisioningOutcome.recoverable.rawValue)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testTransientCleanupRetryClearsJournalOnlyAfterExactAbsenceVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        let email = "rishi-e2e-owner@example.test"
        try journal.recordProvisioningAddress(email, role: .owner)
        try journal.recordProvisioningOutcome(.recoverable, email: email)
        let transport = RecordingTransport(responses: [
            .status(503),
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: journal)

        try await client.deleteProvisionedAccount(email: email)

        let data = try Data(contentsOf: journal.url)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((state?["accounts"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testRecoveryDoesNotRetryNonTransientCleanup4xx() async throws {
        let recorder = LifecycleRecorder()
        let transport = RecordingTransport(responses: [.status(400)])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        await XCTAssertThrowsErrorAsync(try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test"))

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(recorder.events.contains("verified:rishi-e2e-recovery@example.test"))
    }

    func testRecoveryRejectsPlainTextNotFound() async throws {
        let recorder = LifecycleRecorder()
        let transport = RecordingTransport(responses: [
            .status(200),
            .init(statusCode: 404, data: Data("user not found".utf8)),
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        await XCTAssertThrowsErrorAsync(try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test"))

        XCTAssertFalse(recorder.events.contains("verified:rishi-e2e-recovery@example.test"))
    }

    func testRecoveryRejectsGenericSuccessfulVerification() async throws {
        let recorder = LifecycleRecorder()
        let transport = RecordingTransport(responses: [.status(200), .json(["ok": true])])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        await XCTAssertThrowsErrorAsync(try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test"))

        XCTAssertFalse(recorder.events.contains("verified:rishi-e2e-recovery@example.test"))
    }

    func testRecoveryRejectsEvery2xxVerificationResponse() async throws {
        for statusCode in 200..<300 {
            let recorder = LifecycleRecorder()
            let transport = RecordingTransport(responses: [
                .status(200),
                .json(["error": "user not found"], statusCode: statusCode),
            ])
            let client = makeClient(transport: transport, lifecycleRecorder: recorder)

            await XCTAssertThrowsErrorAsync(
                try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test"),
                "HTTP \(statusCode)"
            )

            XCTAssertFalse(recorder.events.contains("verified:rishi-e2e-recovery@example.test"), "HTTP \(statusCode)")
        }
    }

    func testRecoveryRejectsVerificationGateFailureWithoutClearingJournal() async throws {
        let recorder = LifecycleRecorder()
        let transport = RecordingTransport(responses: [.status(200), .status(503)])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        await XCTAssertThrowsErrorAsync(try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test"))

        XCTAssertFalse(recorder.events.contains("verified:rishi-e2e-recovery@example.test"))
    }

    func testRecoveryRejectsNotFoundJSONWithExtraFields() async throws {
        let recorder = LifecycleRecorder()
        let transport = RecordingTransport(responses: [
            .status(200),
            .json(["error": "user not found", "detail": "unexpected"], statusCode: 404),
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        await XCTAssertThrowsErrorAsync(try await client.deleteProvisionedAccount(email: "rishi-e2e-recovery@example.test"))

        XCTAssertFalse(recorder.events.contains("verified:rishi-e2e-recovery@example.test"))
    }

    func testLostResponseWithFailedCompensationLeavesAddressJournaled() async throws {
        let recorder = LifecycleRecorder()
        let transport = SequencedInspectingTransport(steps: [
            .failure(URLError(.networkConnectionLost)) { _ in },
            .response(.status(500)) { _ in },
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: recorder)

        await XCTAssertThrowsErrorAsync(try await client.create(role: .owner))

        XCTAssertEqual(recorder.events, [
            "pending:rishi-e2e-fixed@example.test:owner",
            "recoverable:rishi-e2e-fixed@example.test",
        ])
    }

    func testEveryClientProvisioning4xxRemainsRecoverableUntilVerifiedAbsent() async throws {
        for statusCode in 400..<500 {
            let recorder = LifecycleRecorder()
            let transport = RecordingTransport(responses: [.status(statusCode)])
            let client = makeClient(transport: transport, lifecycleRecorder: recorder)

            await XCTAssertThrowsErrorAsync(try await client.create(role: .participant), "HTTP \(statusCode)")

            XCTAssertEqual(recorder.events, [
                "pending:rishi-e2e-fixed@example.test:participant",
                "recoverable:rishi-e2e-fixed@example.test",
            ], "HTTP \(statusCode)")
            XCTAssertEqual(transport.requests.count, 1, "HTTP \(statusCode)")
        }
    }

    func testVerifiedNormalDeletionRemovesAddressFromJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        let email = "rishi-e2e-owner@example.test"
        try journal.recordProvisioningAddress(email, role: .owner)
        try journal.recordProvisioningOutcome(.recoverable, email: email)
        let transport = RecordingTransport(responses: [
            .json(["ok": true]),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = makeClient(transport: transport, lifecycleRecorder: journal)
        let account = TestAccount(role: .owner, email: email, password: "pw", userID: "u-1", bearerToken: "token-1")

        try await client.delete(account)

        let data = try Data(contentsOf: journal.url)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue((state?["accounts"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testRecoveryAttemptsEveryRecordedAddressAfterAnEarlierFailure() async throws {
        let transport = RecordingTransport(responses: [
            .status(500),
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = makeClient(transport: transport)

        do {
            try await client.recoverProvisionedAccounts([
                "rishi-e2e-first@example.test",
                "rishi-e2e-second@example.test",
            ])
            XCTFail("Expected aggregate recovery failure")
        } catch let error as ProvisionedAccountRecoveryError {
            XCTAssertEqual(error.emails, ["rishi-e2e-first@example.test"])
        }

        XCTAssertEqual(transport.requests.map { $0.url?.lastPathComponent }, [
            "rishi-e2e-first@example.test",
            "rishi-e2e-second@example.test",
            "rishi-e2e-second@example.test",
        ])
    }

    func testRecorderFailurePreventsProvisioningNetworkRequest() async throws {
        let transport = RecordingTransport(responses: [.json(["token": "token", "userId": "user"])])
        let client = makeClient(transport: transport, lifecycleRecorder: ThrowingLifecycleRecorder())

        await XCTAssertThrowsErrorAsync(try await client.create(role: .owner))

        XCTAssertTrue(transport.requests.isEmpty)
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

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[0].url?.path, "/test/sign-in")
        XCTAssertEqual(transport.requests[1].url?.lastPathComponent, "rishi-e2e-fixed@example.test")
        XCTAssertEqual(transport.requests[1].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate-secret")
        XCTAssertEqual(transport.requests[2].url?.lastPathComponent, "rishi-e2e-fixed@example.test")
    }

    func testCreateFailsClosedWhenCompensatingTeardownFails() async throws {
        let transport = FailingProvisioningTransport(cleanupResponses: [.status(500)])
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
        let transport = RecordingTransport(responses: [
            .status(503),
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
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

        do {
            _ = try await client.create(role: .owner)
            XCTFail("Expected provisioning HTTP failure")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .httpFailure(statusCode: 503))
        }
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/rishi-e2e-fixed@example.test")
        XCTAssertEqual(transport.requests[1].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate-secret")
    }

    func testDeleteUsesAuthenticatedUserDeletionRoute() async throws {
        let transport = RecordingTransport(responses: [
            .json(["ok": true]),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .participant, email: "invitee@example.test", password: "pw", userID: "u-1", bearerToken: "token-1")

        try await client.delete(account)

        XCTAssertEqual(transport.requests[0].url?.path, "/api/user")
        XCTAssertEqual(transport.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/invitee@example.test")
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
        let transport = RecordingTransport(responses: [
            .status(401),
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )
        let account = TestAccount(role: .participant, email: "invitee@example.test", password: "pw", userID: "u-1", bearerToken: "expired-token")

        try await client.delete(account)

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[0].url?.path, "/api/user")
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/invitee@example.test")
        XCTAssertEqual(transport.requests[2].url?.path, "/test/users/invitee@example.test")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "X-Test-Auth-Secret"), "gate")
    }

    func testDeleteFailsClosedWhenGatedCleanupCannotBeVerified() async throws {
        let transport = RecordingTransport(responses: [.status(401), .status(503)])
        let client = makeClient(transport: transport)
        let account = TestAccount(role: .participant, email: "invitee@example.test", password: "pw", userID: "u-1", bearerToken: "expired-token")

        await XCTAssertThrowsErrorAsync(try await client.delete(account))

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[1].url?.path, "/test/users/invitee@example.test")
        XCTAssertEqual(transport.requests[2].url?.path, "/test/users/invitee@example.test")
    }

    func testRecoveryDeleteUsesOnlyConfiguredGeneratedEmailNamespace() async throws {
        let transport = RecordingTransport(responses: [
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ])
        let client = TestAccountClient(
            configuration: .init(baseURL: URL(string: "https://api.example.test")!, testAuthSecret: "gate", testDomain: "example.test"),
            transport: transport
        )

        try await client.deleteProvisionedAccount(email: "RISHI-E2E-recovery@example.test")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].url?.path, "/test/users/rishi-e2e-recovery@example.test")

        do {
            try await client.deleteProvisionedAccount(email: "someone-else@example.test")
            XCTFail("Expected recovery namespace validation to fail")
        } catch {
            XCTAssertEqual(error as? TestAccountClientError, .invalidConfiguration("The recovery email is outside the configured test-account namespace."))
        }
        XCTAssertEqual(transport.requests.count, 2)
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

            static func json(_ object: [String: Any], statusCode: Int = 200) -> Response {
                Response(statusCode: statusCode, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
            }

            static func status(_ statusCode: Int) -> Response { Response(statusCode: statusCode, data: Data()) }
        }

        private(set) var requests: [URLRequest] = []
        private var responses: [Response]

        init(responses: [Response]) { self.responses = responses }

        func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            let response = responses.removeFirst()
            return TestAccountHTTPResponse(statusCode: response.statusCode, data: response.data)
        }
    }

    private func makeClient(
        transport: any TestAccountTransport,
        lifecycleRecorder: any TestAccountLifecycleRecording = NoopTestAccountLifecycleRecorder()
    ) -> TestAccountClient {
        TestAccountClient(
            configuration: .init(
                baseURL: URL(string: "https://api.example.test")!,
                testAuthSecret: "gate",
                testDomain: "example.test"
            ),
            transport: transport,
            valueGenerator: { "fixed" },
            lifecycleRecorder: lifecycleRecorder,
            cleanupRetryDelay: .zero
        )
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error. \(message())", file: file, line: line)
        } catch {}
    }

    private final class FailingProvisioningTransport: TestAccountTransport, @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        private var cleanupResponses: [RecordingTransport.Response]

        init(cleanupResponses: [RecordingTransport.Response] = [
            .status(200),
            .json(["error": "user not found"], statusCode: 404),
        ]) {
            self.cleanupResponses = cleanupResponses
        }

        func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
            requests.append(request)
            if requests.count == 1 {
                throw URLError(.networkConnectionLost)
            }
            let response = cleanupResponses.removeFirst()
            return TestAccountHTTPResponse(statusCode: response.statusCode, data: response.data)
        }
    }

    private final class LifecycleRecorder: TestAccountLifecycleRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents: [String] = []

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }

        func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws {
            append("pending:\(email):\(role.rawValue)")
        }

        func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws {
            append("\(outcome.rawValue):\(email)")
        }

        func recordVerifiedDeletion(_ email: String) throws {
            append("verified:\(email)")
        }

        private func append(_ event: String) {
            lock.lock()
            defer { lock.unlock() }
            storedEvents.append(event)
        }
    }

    private struct ThrowingLifecycleRecorder: TestAccountLifecycleRecording {
        struct Failure: Error {}

        func recordProvisioningAddress(_ email: String, role: TestAccountRole) throws { throw Failure() }
        func recordProvisioningOutcome(_ outcome: TestAccountProvisioningOutcome, email: String) throws {}
        func recordVerifiedDeletion(_ email: String) throws {}
    }

    private final class SequencedInspectingTransport: TestAccountTransport, @unchecked Sendable {
        enum Step: @unchecked Sendable {
            case response(RecordingTransport.Response, @Sendable (URLRequest) -> Void)
            case failure(URLError, @Sendable (URLRequest) -> Void)
        }

        private let lock = NSLock()
        private var steps: [Step]
        private(set) var requests: [URLRequest] = []

        init(steps: [Step]) { self.steps = steps }

        func send(_ request: URLRequest) async throws -> TestAccountHTTPResponse {
            let step = lock.withLock {
                requests.append(request)
                return steps.removeFirst()
            }
            switch step {
            case let .response(response, inspect):
                inspect(request)
                return TestAccountHTTPResponse(statusCode: response.statusCode, data: response.data)
            case let .failure(error, inspect):
                inspect(request)
                throw error
            }
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
