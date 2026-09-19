import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingCLITests: XCTestCase {
    func testParsesHelpPreflightExecuteAndExactCleanupArtifactPath() throws {
        XCTAssertEqual(try SharedReadingCLI.parse(arguments: []), .execute)
        XCTAssertEqual(try SharedReadingCLI.parse(arguments: ["--help"]), .help)
        XCTAssertEqual(try SharedReadingCLI.parse(arguments: ["-h"]), .help)
        XCTAssertEqual(try SharedReadingCLI.parse(arguments: ["--preflight"]), .preflight)
        XCTAssertEqual(
            try SharedReadingCLI.parse(arguments: ["--cleanup-manifest=/private/tmp/rishi-shared-reading-run/recovery.json"]),
            .recovery(URL(fileURLWithPath: "/private/tmp/rishi-shared-reading-run/recovery.json"))
        )
    }

    func testRejectsUnknownMixedAndInvalidCleanupArguments() throws {
        for arguments in [
            ["--unknown"],
            ["--help", "--unknown"],
            ["--preflight", "extra"],
            ["--cleanup-manifest="],
            ["--cleanup-manifest=relative/recovery.json"],
            ["--cleanup-manifest=/private/tmp/../tmp/recovery.json"],
        ] {
            XCTAssertThrowsError(try SharedReadingCLI.parse(arguments: arguments), "arguments: \(arguments)")
        }
    }

    func testHelpReturnsUsageWithoutInvokingAnyAction() async throws {
        let recorder = CLIActionRecorder()
        let lines = try await SharedReadingCLI.run(
            arguments: ["--help"],
            environment: [:],
            actions: makeActions(recorder: recorder)
        )

        let events = await recorder.eventSnapshot()
        XCTAssertEqual(events, [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("--preflight"))
        XCTAssertTrue(lines[0].contains("--cleanup-manifest=PATH"))
    }

    func testPreflightInvokesOnlySharedRunnerAndReturnsRedactedStatus() async throws {
        let recorder = CLIActionRecorder()
        let lines = try await SharedReadingCLI.run(
            arguments: ["--preflight"],
            environment: ["sentinel": "value"],
            actions: makeActions(recorder: recorder)
        )

        let events = await recorder.eventSnapshot()
        XCTAssertEqual(events, ["preflight:value"])
        XCTAssertEqual(lines, ["Shared-reading E2E preflight passed."])
    }

    func testExecuteInvokesOnlySharedRunnerAndReturnsExactRedactedEvidenceLines() async throws {
        let recorder = CLIActionRecorder()
        let lines = try await SharedReadingCLI.run(
            arguments: [],
            environment: ["sentinel": "value"],
            actions: makeActions(recorder: recorder)
        )

        let events = await recorder.eventSnapshot()
        XCTAssertEqual(events, ["execute:value"])
        XCTAssertEqual(lines, [
            "Shared-reading E2E completed: run-123",
            "Participant observed sequence: 7",
            "Temporary accounts deleted and verified: 2",
        ])
    }

    func testRecoveryAcceptsOnlyRecoveryConfigurationAndInvokesCompleteRecoveryDelegate() async throws {
        let recorder = CLIActionRecorder()
        let artifact = "/private/tmp/rishi-shared-reading-run/recovery.json"
        let environment = [
            "RISHI_E2E_ALLOW_NETWORK": "1",
            "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
            "RISHI_E2E_TEST_AUTH_SECRET": "test-secret",
            "RISHI_E2E_TEST_DOMAIN": "example.test",
            "RISHI_E2E_TEMP_ROOT": "/private/tmp",
            "RISHI_APPLE_XCODE_BUILD_LOCK_PATH": "/private/tmp/rishi-apple-xcode-build.lock",
        ]

        let lines = try await SharedReadingCLI.run(
            arguments: ["--cleanup-manifest=\(artifact)"],
            environment: environment,
            actions: makeActions(recorder: recorder)
        )

        let events = await recorder.eventSnapshot()
        let capturedConfiguration = await recorder.capturedRecoveryConfiguration()
        XCTAssertEqual(events, ["recovery:\(artifact)"])
        let configuration = try XCTUnwrap(capturedConfiguration)
        XCTAssertEqual(configuration.baseURL, URL(string: "https://api-e2e.fidexa.org"))
        XCTAssertEqual(configuration.testAuthSecret, "test-secret")
        XCTAssertEqual(configuration.testDomain, "example.test")
        XCTAssertEqual(configuration.temporaryRoot.path, "/private/tmp")
        XCTAssertEqual(configuration.buildLockURL.path, "/private/tmp/rishi-apple-xcode-build.lock")
        XCTAssertEqual(lines, ["Shared-reading E2E recovery completed."])
    }

    func testRecoveryAcceptsTheExactE2EAPIOriginWithoutRequiringWebSocketConfiguration() async throws {
        let recorder = CLIActionRecorder()
        let artifact = "/private/tmp/rishi-shared-reading-run/recovery.json"
        let environment = [
            "RISHI_E2E_ALLOW_NETWORK": "1",
            "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
            "RISHI_E2E_TEST_AUTH_SECRET": "test-secret",
            "RISHI_E2E_TEST_DOMAIN": "example.test",
            "RISHI_E2E_TEMP_ROOT": "/private/tmp",
            "RISHI_APPLE_XCODE_BUILD_LOCK_PATH": "/private/tmp/rishi-apple-xcode-build.lock",
        ]

        _ = try await SharedReadingCLI.run(
            arguments: ["--cleanup-manifest=\(artifact)"],
            environment: environment,
            actions: makeActions(recorder: recorder)
        )

        let captured = await recorder.capturedRecoveryConfiguration()
        let configuration = try XCTUnwrap(captured)
        XCTAssertEqual(configuration.baseURL, URL(string: "https://api-e2e.fidexa.org"))
    }

    private func makeActions(recorder: CLIActionRecorder) -> SharedReadingCLI.Actions {
        SharedReadingCLI.Actions(
            preflight: { environment in
                await recorder.record("preflight:\(environment["sentinel"] ?? "missing")")
            },
            execute: { environment in
                await recorder.record("execute:\(environment["sentinel"] ?? "missing")")
                return SharedReadingLiveRunEvidence(
                    runID: "run-123",
                    participantProgressSequence: 7,
                    deletedAccountCount: 2
                )
            },
            recover: { artifact, configuration in
                await recorder.recordRecovery(artifact: artifact, configuration: configuration)
            }
        )
    }
}

private actor CLIActionRecorder {
    private(set) var events: [String] = []
    private(set) var recoveryConfiguration: SharedReadingCLI.RecoveryConfiguration?

    func record(_ event: String) {
        events.append(event)
    }

    func eventSnapshot() -> [String] {
        events
    }

    func capturedRecoveryConfiguration() -> SharedReadingCLI.RecoveryConfiguration? {
        recoveryConfiguration
    }

    func recordRecovery(
        artifact: URL,
        configuration: SharedReadingCLI.RecoveryConfiguration
    ) {
        events.append("recovery:\(artifact.path)")
        recoveryConfiguration = configuration
    }
}
