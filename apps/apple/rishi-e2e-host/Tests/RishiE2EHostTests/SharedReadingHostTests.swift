import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingHostTests: XCTestCase {
    func testStageLogPathIsPeerScopedAndOutsideCredentialManifest() {
        let root = URL(fileURLWithPath: "/private/tmp/rishi-results", isDirectory: true)

        XCTAssertEqual(
            XCTestPeerProcessRunner.stageLogURL(
                resultBundleRoot: root,
                runID: "run-123",
                role: .owner
            ).path,
            "/private/tmp/rishi-results/run-123-owner.stages"
        )
        XCTAssertEqual(
            XCTestPeerProcessRunner.stageLogURL(
                resultBundleRoot: root,
                runID: "run-123",
                role: .participant
            ).path,
            "/private/tmp/rishi-results/run-123-participant.stages"
        )
    }

    func testSimulatorValidationRequiresExactIPhone17ProAndUDID() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "devices": [
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    ["name": "iPhone 17 Pro", "udid": "target-udid", "state": "Shutdown"],
                    ["name": "iPhone 17", "udid": "other-udid", "state": "Booted"]
                ]
            ]
        ])

        XCTAssertTrue(XCTestPeerProcessRunner.isConfiguredIPhone17ProAvailable(in: data, simulatorID: "target-udid"))
        XCTAssertFalse(XCTestPeerProcessRunner.isConfiguredIPhone17ProAvailable(in: data, simulatorID: "other-udid"))
        XCTAssertFalse(XCTestPeerProcessRunner.isConfiguredIPhone17ProAvailable(in: data, simulatorID: "missing-udid"))
    }

    func testDefaultInviteTimeoutAllowsColdRealAuthAndInboundSync() {
        let configuration = SharedReadingHost.Configuration(
            runID: "run-timeout",
            fixture: .init(role: .owner, format: .epub, basename: "book.epub", sha256: String(repeating: "a", count: 64), byteSize: 1),
            manifestURL: URL(fileURLWithPath: "/private/tmp/manifest.json"),
            ownerDestination: .catalyst,
            participantDestination: .iPhone17Pro
        )

        XCTAssertEqual(configuration.inviteTimeout, .seconds(300))
    }

    func testSimulatorServiceFailureDoesNotAttemptErase() async throws {
        let runner = XCTestPeerProcessRunner(
            configuration: .init(
                projectPath: URL(fileURLWithPath: "/tmp/rishi.xcodeproj"),
                simulatorID: "target-udid",
                derivedDataRoot: URL(fileURLWithPath: "/tmp/rishi-derived"),
                resultBundleRoot: URL(fileURLWithPath: "/tmp/rishi-results"),
                allowSimulatorReset: true
            ),
            processRunner: FailingProcessRunner()
        )

        do {
            try await runner.reset(target: .iPhone17Pro)
            XCTFail("Expected CoreSimulatorService failure")
        } catch {
            XCTAssertEqual(error as? HostError, .simulatorServiceUnavailable)
        }
    }

    func testSimulatorShutdownTreatsAlreadyShutdownAsSuccess() {
        XCTAssertTrue(XCTestPeerProcessRunner.simulatorShutdownCompleted(
            ProcessResult(exitStatus: 0, stdout: "", stderr: "")
        ))
        XCTAssertTrue(XCTestPeerProcessRunner.simulatorShutdownCompleted(
            ProcessResult(
                exitStatus: 149,
                stdout: "",
                stderr: "Unable to shutdown device in current state: Shutdown"
            )
        ))
        XCTAssertFalse(XCTestPeerProcessRunner.simulatorShutdownCompleted(
            ProcessResult(exitStatus: 149, stdout: "", stderr: "CoreSimulatorService unavailable")
        ))
    }

    func testLifecycleResetsLaunchesWaitsCleansAccountsAndManifest() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events)
        let peers = FakePeers(events: events)
        let rendezvous = FakeRendezvous(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-1",
                fixture: .init(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "a", count: 64), byteSize: 10),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous
        )

        try await host.run()

        XCTAssertEqual(Array(events.values.prefix(10)), [
            "account:preflight", "preflight", "reset:catalyst", "reset:iPhone17Pro", "account:create:owner", "account:create:participant",
            "manifest:write", "prepare:owner", "prepare:participant", "launch:owner"
        ])
        let rendezvousIndex = try XCTUnwrap(events.values.firstIndex(of: "rendezvous:wait"))
        XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "wait:owner")), rendezvousIndex)
        XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "account:wait-book:owner")), rendezvousIndex)
        XCTAssertEqual(Array(events.values.suffix(from: rendezvousIndex)), [
            "rendezvous:wait", "launch:participant",
            "wait:participant", "account:delete:owner", "account:verify:owner",
            "account:delete:participant", "account:verify:participant", "manifest:remove"
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testProvisionedFixtureIsReadyBeforeEitherPeerLaunches() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events)
        let peers = FakePeers(events: events)
        let rendezvous = FakeRendezvous(events: events)
        let provisioner = FakeFixtureProvisioner(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-preprovisioned-fixture",
                fixture: .init(role: .owner, format: .epub, basename: "book.epub", sha256: String(repeating: "a", count: 64), byteSize: 10),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro,
                fixturePath: URL(fileURLWithPath: "/private/tmp/book.epub")
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous,
            fixtureProvisioner: provisioner
        )

        try await host.run()

        let values = events.values
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "fixture:provision")), try XCTUnwrap(values.firstIndex(of: "manifest:write")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "fixture:provision")), try XCTUnwrap(values.firstIndex(of: "launch:owner")))
        XCTAssertLessThan(try XCTUnwrap(values.firstIndex(of: "account:wait-book:owner")), try XCTUnwrap(values.firstIndex(of: "launch:owner")))
    }

    func testFailedPeerStillCleansBothAccountsAndManifest() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events)
        let peers = FakePeers(events: events, ownerStatus: 9)
        let rendezvous = FakeRendezvous(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-2",
                fixture: .init(role: .owner, format: .epub, basename: "book.epub", sha256: String(repeating: "b", count: 64), byteSize: 20),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous
        )

        do {
            try await host.run()
            XCTFail("Expected failed peer to fail the host run")
        } catch {
            XCTAssertEqual(error as? HostError, .processFailed(role: .owner, status: 9))
        }
        XCTAssertTrue(events.values.contains("account:wait-book:owner"))
        XCTAssertTrue(events.values.contains("account:delete:owner"))
        XCTAssertTrue(events.values.contains("account:delete:participant"))
        XCTAssertTrue(events.values.contains("manifest:remove"))
    }

    func testFailedAccountDeletionPreservesRecoveryArtifactsAndSkipsVerification() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events, deleteErrorRole: .owner)
        let peers = FakePeers(events: events)
        let rendezvous = FakeRendezvous(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-delete-failure",
                fixture: .init(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "a", count: 64), byteSize: 10),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous
        )

        do {
            try await host.run()
            XCTFail("Expected cleanup failure to fail the host run")
        } catch {
            XCTAssertEqual(error as? HostError, .cleanupFailed)
        }
        XCTAssertTrue(events.values.contains("account:delete:owner"))
        XCTAssertFalse(events.values.contains("account:verify:owner"))
        XCTAssertTrue(events.values.contains("account:delete:participant"))
        XCTAssertFalse(events.values.contains("manifest:remove"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        try? FileManager.default.removeItem(at: manifestURL)
    }

    func testFailedOwnerStopStillAttemptsIndependentParticipantCleanup() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events)
        let peers = FakePeers(events: events, cancelErrorRole: .owner)
        let rendezvous = FakeRendezvous(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-stop-failure",
                fixture: .init(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "a", count: 64), byteSize: 10),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous
        )

        do {
            try await host.run()
            XCTFail("Expected peer-stop cleanup failure to fail the host run")
        } catch {
            XCTAssertEqual(error as? HostError, .cleanupFailed)
        }
        XCTAssertTrue(events.values.contains("account:delete:participant"))
        XCTAssertTrue(events.values.contains("account:verify:participant"))
        XCTAssertFalse(events.values.contains("account:delete:owner"))
        XCTAssertFalse(events.values.contains("manifest:remove"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        try? FileManager.default.removeItem(at: manifestURL)
    }

    func testRunReportPreservesPrimaryFailureWhenCleanupAlsoFails() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events)
        let peers = FakePeers(events: events, ownerStatus: 9, cancelErrorRole: .owner)
        let rendezvous = FakeRendezvous(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-peer-and-cleanup-failure",
                fixture: .init(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "a", count: 64), byteSize: 10),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous
        )

        let report = await host.runReport()

        XCTAssertEqual(report.primaryFailure, .processFailed(role: .owner, status: 9))
        XCTAssertTrue(report.cleanupFailed)
        XCTAssertFalse(events.values.contains("account:delete:owner"))
        XCTAssertTrue(events.values.contains("account:delete:participant"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        try? FileManager.default.removeItem(at: manifestURL)
    }

    func testOwnerFailureCancelsFixtureWaitBeforeParticipantLaunch() async throws {
        let events = EventRecorder()
        let accounts = FakeAccounts(events: events, fixtureWaitDelay: .seconds(1))
        let peers = FakePeers(events: events, ownerStatus: 9)
        let rendezvous = FakeRendezvous(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: .init(
                runID: "run-owner-failure-before-fixture",
                fixture: .init(role: .owner, format: .epub, basename: "book.epub", sha256: String(repeating: "c", count: 64), byteSize: 20),
                manifestURL: manifestURL,
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro
            ),
            accounts: accounts,
            peers: peers,
            rendezvous: rendezvous
        )

        let report = await host.runReport()

        XCTAssertEqual(report.primaryFailure, .processFailed(role: .owner, status: 9))
        XCTAssertFalse(events.values.contains("launch:participant"))
        XCTAssertTrue(events.values.contains("account:wait-book:cancelled"))
    }

    func testRedactedManifestContainsNoCredentialsOrSourcePath() throws {
        let fixturePath = "/private/user/book.pdf"
        let fixture = RealBookFixture.Manifest(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "a", count: 64), byteSize: 10)
        let manifest = HostRunManifest(
            runID: "run-redacted",
            owner: TestAccount(role: .owner, email: "owner@example.test", password: "password-secret", userID: "owner-id", bearerToken: "bearer-secret"),
            participant: TestAccount(role: .participant, email: "participant@example.test", password: "participant-password", userID: "participant-id", bearerToken: "participant-token"),
            fixture: fixture,
            ownerDestination: .catalyst,
            participantDestination: .iPhone17Pro,
            rendezvousPath: fixturePath
        )

        XCTAssertFalse(manifest.redactedJSON.contains("password-secret"))
        XCTAssertFalse(manifest.redactedJSON.contains("bearer-secret"))
        XCTAssertFalse(manifest.redactedJSON.contains(fixturePath))
        XCTAssertTrue(manifest.redactedJSON.contains("book.pdf"))
        let encoded = try JSONEncoder().encode(manifest)
        let onDiskJSON = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(onDiskJSON.contains("bearer-secret"))
        XCTAssertFalse(onDiskJSON.contains("owner-id"))
        XCTAssertFalse(onDiskJSON.contains("password-secret"))
        XCTAssertFalse(onDiskJSON.contains("credentialPath"))
        XCTAssertTrue(onDiskJSON.contains("owner@example.test"))
        XCTAssertTrue(manifest.description.isEmpty || !manifest.description.contains("password-secret"))
    }

    func testRendezvousStoreDoesNotPersistPeerPasswords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = HostRunManifest(
            runID: "run-no-password-files",
            owner: TestAccount(role: .owner, email: "owner@example.test", password: "owner-secret", userID: "owner-id", bearerToken: "owner-token"),
            participant: TestAccount(role: .participant, email: "participant@example.test", password: "participant-secret", userID: "participant-id", bearerToken: "participant-token"),
            fixture: .init(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "a", count: 64), byteSize: 10),
            manifestPath: manifestURL.path,
            ownerDestination: .catalyst,
            participantDestination: .iPhone17Pro,
            rendezvousPath: directory.appendingPathComponent("invite.json").path
        )

        try RendezvousFileStore().writeManifest(manifest, to: manifestURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(manifestURL.path).owner-credentials"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(manifestURL.path).participant-credentials"))
        let persisted = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains("owner-secret"))
        XCTAssertFalse(persisted.contains("participant-secret"))
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [String] = []
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    }

    private struct FakeAccounts: TestAccountManaging {
        let events: EventRecorder
        let deleteErrorRole: TestAccountRole?
        let fixtureWaitDelay: Duration?
        init(events: EventRecorder, deleteErrorRole: TestAccountRole? = nil, fixtureWaitDelay: Duration? = nil) {
            self.events = events
            self.deleteErrorRole = deleteErrorRole
            self.fixtureWaitDelay = fixtureWaitDelay
        }
        func preflight() async throws { events.append("account:preflight") }
        func create(role: TestAccountRole) async throws -> TestAccount {
            events.append("account:create:\(role.rawValue)")
            return TestAccount(role: role, email: "\(role.rawValue)@example.test", password: "pw", userID: role.rawValue, bearerToken: "token")
        }
        func waitForBookUpload(_ account: TestAccount, expectedSHA256: String, timeout: Duration) async throws {
            events.append("account:wait-book:\(account.role.rawValue)")
            if let fixtureWaitDelay {
                do {
                    try await Task.sleep(for: fixtureWaitDelay)
                } catch {
                    events.append("account:wait-book:cancelled")
                    throw error
                }
            }
        }
        func delete(_ account: TestAccount) async throws {
            events.append("account:delete:\(account.role.rawValue)")
            if account.role == deleteErrorRole { throw TestAccountClientError.httpFailure(statusCode: 500) }
        }
        func verifyDeleted(_ account: TestAccount) async throws { events.append("account:verify:\(account.role.rawValue)") }
    }

    private struct FakeFixtureProvisioner: FixtureBookProvisioning {
        let events: EventRecorder

        func provision(_ fixture: RealBookFixture, for account: TestAccount) async throws -> ProvisionedFixtureBook {
            events.append("fixture:provision")
            return ProvisionedFixtureBook(
                bookID: UUID(),
                r2Key: "books/\(account.userID)/fixture.epub",
                manifest: fixture.manifest
            )
        }
    }

    private struct FakePeers: SharedReadingPeerRunner {
        let events: EventRecorder
        let ownerStatus: Int32
        let cancelErrorRole: TestAccountRole?
        init(events: EventRecorder, ownerStatus: Int32 = 0, cancelErrorRole: TestAccountRole? = nil) {
            self.events = events
            self.ownerStatus = ownerStatus
            self.cancelErrorRole = cancelErrorRole
        }
        func preflight() async throws { events.append("preflight") }
        func reset(target: SharedReadingDestination) async throws { events.append("reset:\(target.rawValue)") }
        func prepare(role: TestAccountRole, account: TestAccount, manifest: HostRunManifest, destination: SharedReadingDestination) async throws { events.append("prepare:\(role.rawValue)") }
        func launch(role: TestAccountRole, account: TestAccount, manifest: HostRunManifest, destination: SharedReadingDestination, inviteToken: String?) async throws -> SharedReadingPeerHandle {
            events.append("launch:\(role.rawValue)")
            return .init(role: role, status: role == .owner ? ownerStatus : 0)
        }
        func wait(_ handle: SharedReadingPeerHandle) async throws -> ProcessResult {
            events.append("wait:\(handle.role.rawValue)")
            return ProcessResult(exitStatus: handle.status, stdout: "", stderr: "")
        }
        func cancel(_ handle: SharedReadingPeerHandle) async throws {
            if handle.role == cancelErrorRole { throw TestAccountClientError.httpFailure(statusCode: 500) }
        }
    }

    private struct FakeRendezvous: SharedReadingRendezvous {
        let events: EventRecorder
        func writeManifest(_ manifest: HostRunManifest, to url: URL) throws { events.append("manifest:write"); try Data("manifest".utf8).write(to: url) }
        func waitForInvite(at url: URL, timeout: Duration) async throws -> String { events.append("rendezvous:wait"); return "invite-token" }
        func removeManifest(at url: URL) throws { events.append("manifest:remove"); try? FileManager.default.removeItem(at: url) }
    }

    private struct FailingProcessRunner: ProcessRunner {
        func start(_ request: ProcessRequest) throws -> any ProcessHandle {
            FailingProcessHandle()
        }
    }

    private struct FailingProcessHandle: ProcessHandle {
        func wait() async throws -> ProcessResult {
            ProcessResult(exitStatus: 1, stdout: "", stderr: "CoreSimulatorService connection became invalid")
        }

        func cancel() {}
    }
}
