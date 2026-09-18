import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingHostTests: XCTestCase {
    func testSafeDestinationPreflightDoesNotResolvePackagesOrAcquireBuildLock() async throws {
        let process = CapturingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "Xcode 27", stderr: ""),
            ProcessResult(exitStatus: 0, stdout: #"{"devices":{"runtime":[{"name":"iPhone 17 Pro","udid":"source-udid"}]}}"#, stderr: ""),
        ])
        let runner = XCTestPeerProcessRunner(
            configuration: .init(
                projectPath: URL(fileURLWithPath: "/private/tmp/rishi.xcodeproj"),
                simulatorID: "source-udid",
                derivedDataRoot: FileManager.default.temporaryDirectory,
                resultBundleRoot: FileManager.default.temporaryDirectory
            ),
            processRunner: process
        )

        try await runner.preflight()

        XCTAssertEqual(process.requests.count, 2)
        XCTAssertFalse(process.requests.flatMap(\.arguments).contains("-resolvePackageDependencies"))
    }

    func testPackagePreparationUsesCallerHeldLockWithoutNestedAcquisition() async throws {
        let process = CapturingProcessRunner(results: [
            ProcessResult(exitStatus: 0, stdout: "", stderr: "")
        ])
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let verifyCount = LockedCounter()
        let preparer = PackageDependencyPreparer(
            processRunner: process,
            verifyOwnership: { ownership in
                XCTAssertEqual(ownership, lock.ownership)
                verifyCount.increment()
            }
        )

        try await preparer.preparePackageDependencies(
            project: URL(fileURLWithPath: "/private/tmp/rishi.xcodeproj"),
            derivedDataRoot: URL(fileURLWithPath: "/private/tmp/derived", isDirectory: true),
            whileHolding: lock
        )

        let request = try XCTUnwrap(process.requests.first)
        XCTAssertEqual(request.executablePath, "/usr/bin/xcodebuild")
        XCTAssertTrue(request.arguments.contains("-resolvePackageDependencies"))
        XCTAssertFalse(request.arguments.contains("-destination"))
        XCTAssertEqual(verifyCount.value, 2)
        XCTAssertFalse(events.values.contains("lock:release"))
    }

    func testAppLaunchNonceExistsOnlyInUITargetAppEnvironmentVariables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-xctestrun-\(UUID().uuidString)", isDirectory: true)
        let products = root.appendingPathComponent("Build/Products", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = products.appendingPathComponent("source.xctestrun")
        let plist: [String: Any] = ["UITests": ["TestBundlePath": "__TESTROOT__/rishiUITests.xctest"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: source)
        let runner = XCTestPeerProcessRunner(configuration: .init(
            projectPath: URL(fileURLWithPath: "/private/tmp/rishi.xcodeproj"),
            simulatorID: "sim",
            derivedDataRoot: root.deletingLastPathComponent(),
            resultBundleRoot: root,
            rendezvousEnvironment: ["RISHI_E2E_RENDEZVOUS_SECRET": "relay-secret"],
            catalystRegistration: .init(runnerNonce: "runner-nonce", appNonce: "app-nonce")
        ))
        let account = TestAccount(role: .owner, email: "owner@example.test", password: "pw", userID: "id", bearerToken: "token")
        let manifest = HostRunManifest(
            runID: "run-nonces", owner: account,
            participant: TestAccount(role: .participant, email: "p@example.test", password: "pw", userID: "p", bearerToken: "token"),
            fixture: .init(role: .owner, format: .epub, basename: "book.epub", sha256: String(repeating: "a", count: 64), byteSize: 1),
            ownerDestination: .catalyst, participantDestination: .iPhone17Pro,
            rendezvousPath: "/private/tmp/invite"
        )

        let clone = try runner.makeRoleTestRunSpecification(role: .owner, derivedData: root, manifest: manifest, inviteToken: nil)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: clone), format: nil) as? [String: Any])
        let target = try XCTUnwrap(decoded["UITests"] as? [String: Any])
        let runnerEnvironment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
        let appEnvironment = try XCTUnwrap(target["UITargetAppEnvironmentVariables"] as? [String: String])
        XCTAssertEqual(runnerEnvironment["RISHI_E2E_RUNNER_REGISTRATION_NONCE"], "runner-nonce")
        XCTAssertNil(runnerEnvironment["RISHI_E2E_APP_REGISTRATION_NONCE"])
        XCTAssertEqual(appEnvironment["RISHI_E2E_APP_REGISTRATION_NONCE"], "app-nonce")
        XCTAssertNil(appEnvironment["RISHI_E2E_RUNNER_REGISTRATION_NONCE"])
        XCTAssertEqual(runnerEnvironment["RISHI_E2E_RENDEZVOUS_SECRET"], "relay-secret")
        XCTAssertEqual(appEnvironment["RISHI_E2E_RENDEZVOUS_SECRET"], "relay-secret")
    }

    func testPeerRegistrationNonceAndRoleAreWrittenToXctestrunEnvironment() throws {
        try testAppLaunchNonceExistsOnlyInUITargetAppEnvironmentVariables()
    }

    func testHostReservesDistinctRunnerAndAppNoncesBeforeOwnerTestLaunch() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: packageRoot.appendingPathComponent("Sources/RishiE2EHost/SharedReadingLiveRun.swift"))
        let runner = try XCTUnwrap(source.range(of: "kind: .runner"))
        let app = try XCTUnwrap(source.range(of: "kind: .app"))
        let host = try XCTUnwrap(source.range(of: "private func runHost()"))
        XCTAssertLessThan(runner.lowerBound, app.lowerBound)
        XCTAssertLessThan(app.lowerBound, host.lowerBound)
        XCTAssertTrue(source.contains("runnerNonce: runnerNonce, appNonce: appNonce"))
    }

    func testLiveOwnerUsesResetOnItsSingleRegisteredLaunchWithoutDeferredRelaunch() throws {
        let owner = try uiTestSource(named: "SharedReadingOwnerUITests.swift")
        let support = try uiTestSource(named: "SharedReadingTestSupport.swift")
        XCTAssertEqual(owner.components(separatedBy: "support.launch(role: .owner)").count - 1, 1)
        XCTAssertTrue(support.contains("app.launchArguments += [\"--rishi-e2e-reset\"]"))
        XCTAssertFalse(owner.contains("resetLocalState"))
        XCTAssertFalse(owner.contains("defer { try? support.launch"))
    }

    func testDisposableParticipantKeepsRejoinRestartButSkipsDeferredCleanupRelaunch() throws {
        let source = try uiTestSource(named: "SharedReadingParticipantUITests.swift")
        XCTAssertTrue(source.contains("restartPreservingLocalState"))
        XCTAssertFalse(source.contains("defer { try? support.launch"))
        XCTAssertTrue(source.contains("terminateWithoutRelaunch"))
    }
    func testHostInvokesOwnedResourceCleanupBeforeEitherAccountDeletion() async throws {
        let events = EventRecorder()
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: makeConfiguration(manifestURL: manifestURL),
            accounts: FakeAccounts(events: events),
            peers: FakePeers(events: events),
            rendezvous: FakeRendezvous(events: events),
            preAccountCleanup: { events.append("owned-resources:cleanup") }
        )

        try await host.run()

        let cleanup = try XCTUnwrap(events.values.firstIndex(of: "owned-resources:cleanup"))
        XCTAssertLessThan(cleanup, try XCTUnwrap(events.values.firstIndex(of: "account:delete:owner")))
        XCTAssertLessThan(cleanup, try XCTUnwrap(events.values.firstIndex(of: "account:delete:participant")))
    }

    func testHostSkipsAccountDeletionWhenOwnedResourceCleanupIsUnproven() async throws {
        let events = EventRecorder()
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        let host = SharedReadingHost(
            configuration: makeConfiguration(manifestURL: manifestURL),
            accounts: FakeAccounts(events: events),
            peers: FakePeers(events: events),
            rendezvous: FakeRendezvous(events: events),
            preAccountCleanup: {
                events.append("owned-resources:cleanup")
                throw ResourcePreflightError("unproven")
            }
        )

        let report = try await host.runReport()

        XCTAssertTrue(report.cleanupFailed)
        XCTAssertFalse(events.values.contains("account:delete:owner"))
        XCTAssertFalse(events.values.contains("account:delete:participant"))
    }

    private func uiTestSource(named name: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: packageRoot.deletingLastPathComponent().appendingPathComponent("rishi/rishiUITests/\(name)"))
    }
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

        let report = try await host.runReport()

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

        let report = try await host.runReport()

        XCTAssertEqual(report.primaryFailure, .processFailed(role: .owner, status: 9))
        XCTAssertFalse(events.values.contains("launch:participant"))
        XCTAssertTrue(events.values.contains("account:wait-book:cancelled"))
    }

    func testBuildLockOwnershipIsRecordedBeforeAnyHostActionAndClearedAfterVerifiedRelease() async throws {
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = makeHost(
            events: events,
            manifestURL: manifestURL,
            buildLockRecorder: recorder,
            acquireBuildLock: {
                events.append("lock:acquire")
                return lock
            }
        )

        try await host.run()

        XCTAssertEqual(Array(events.values.prefix(3)), [
            "lock:acquire", "journal:record-lock", "account:preflight",
        ])
        XCTAssertEqual(Array(events.values.suffix(2)), ["lock:release", "journal:clear-lock"])
        XCTAssertEqual(recorder.recordedOwnership, nil)
    }

    func testBuildLockJournalFailureReleasesExactLockBeforeHostActionsAndFails() async throws {
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events, failFirstRecord: true)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = makeHost(
            events: events,
            manifestURL: manifestURL,
            buildLockRecorder: recorder,
            acquireBuildLock: {
                events.append("lock:acquire")
                return lock
            }
        )

        let report = try await host.runReport()

        XCTAssertNotNil(report.primaryFailure)
        XCTAssertEqual(Array(events.values.prefix(3)), ["lock:acquire", "journal:record-lock", "lock:release"])
        XCTAssertFalse(events.values.contains("account:preflight"))
        XCTAssertFalse(events.values.contains("preflight"))
        XCTAssertFalse(events.values.contains(where: { $0.hasPrefix("reset:") }))
        XCTAssertFalse(events.values.contains("lock:transfer"))
    }

    func testUnprovenCleanupTransfersAlreadyJournaledExactOwnership() async throws {
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = makeHost(
            events: events,
            manifestURL: manifestURL,
            accounts: FakeAccounts(events: events, deleteErrorRole: .owner),
            buildLockRecorder: recorder,
            acquireBuildLock: {
                events.append("lock:acquire")
                return lock
            }
        )

        let report = try await host.runReport()

        XCTAssertTrue(report.cleanupFailed)
        XCTAssertEqual(events.values.filter { $0 == "journal:record-lock" }.count, 1)
        XCTAssertEqual(events.values.last, "lock:transfer")
        XCTAssertFalse(events.values.contains("lock:release"))
        XCTAssertEqual(recorder.recordedOwnership, lock.ownership)
    }

    func testReleaseFailureRetainsJournalThenTransfersOwnership() async throws {
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events, failRelease: true)
        let recorder = FakeBuildLockRecorder(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = makeHost(
            events: events,
            manifestURL: manifestURL,
            buildLockRecorder: recorder,
            acquireBuildLock: {
                events.append("lock:acquire")
                return lock
            }
        )

        let report = try await host.runReport()

        XCTAssertTrue(report.cleanupFailed)
        XCTAssertEqual(events.values.filter { $0 == "journal:record-lock" }.count, 1)
        XCTAssertEqual(Array(events.values.suffix(2)), ["lock:release", "lock:transfer"])
        XCTAssertFalse(events.values.contains("journal:clear-lock"))
        XCTAssertEqual(recorder.recordedOwnership, lock.ownership)
    }

    func testPreparedProductionLockIsJournaledBeforeHostConstructionAndManagedByHost() async throws {
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events)
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = try makeBoundPreparedHost(
            events: events,
            manifestURL: manifestURL,
            recorder: recorder,
            acquireBuildLock: {
                events.append("lock:acquire")
                return lock
            }
        )
        XCTAssertEqual(events.values, ["lock:acquire", "journal:record-lock"])

        try await host.run()

        XCTAssertEqual(events.values.filter { $0 == "lock:acquire" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "journal:record-lock" }.count, 1)
        XCTAssertEqual(Array(events.values.suffix(2)), ["lock:release", "journal:clear-lock"])
    }

    func testPreparedBuildLockCanBeConsumedOnlyOnceSequentially() throws {
        let events = EventRecorder()
        let prepared = try SharedReadingHost.prepareBuildLock(
            recorder: FakeBuildLockRecorder(events: events),
            acquire: { FakeBuildLock(events: events) }
        )
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        _ = try makeHost(preparedBuildLock: prepared, events: events, manifestURL: manifestURL)
        XCTAssertThrowsError(
            try makeHost(preparedBuildLock: prepared, events: events, manifestURL: manifestURL)
        )
        XCTAssertEqual(events.values.filter { $0 == "journal:record-lock" }.count, 1)
    }

    func testPreparedBuildLockCanBeConsumedOnlyOnceConcurrently() async throws {
        let events = EventRecorder()
        let prepared = try SharedReadingHost.prepareBuildLock(
            recorder: FakeBuildLockRecorder(events: events),
            acquire: { FakeBuildLock(events: events) }
        )
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let configuration = makeConfiguration(manifestURL: manifestURL)

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try SharedReadingHost(
                            configuration: configuration,
                            accounts: FakeAccounts(events: events),
                            peers: FakePeers(events: events),
                            rendezvous: FakeRendezvous(events: events),
                            preparedBuildLock: prepared
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(outcomes.filter { !$0 }.count, 1)
    }

    func testPreparedHostCanRunOnlyOnceSequentiallyWithoutRepeatingSideEffects() async throws {
        let events = EventRecorder()
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = try makeBoundPreparedHost(
            events: events,
            manifestURL: manifestURL,
            recorder: FakeBuildLockRecorder(events: events),
            acquireBuildLock: { FakeBuildLock(events: events) }
        )

        _ = try await host.runReport()
        let eventsAfterFirstRun = events.values
        do {
            _ = try await host.runReport()
            XCTFail("A second host execution must throw")
        } catch {
            XCTAssertEqual(error as? HostError, .alreadyExecuted)
        }

        XCTAssertEqual(events.values, eventsAfterFirstRun)
        XCTAssertEqual(events.values.filter { $0 == "account:preflight" }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "lock:release" }.count, 1)
    }

    func testConcurrentHostExecutionRejectsSecondCallBeforeAnySideEffect() async throws {
        let events = EventRecorder()
        let barrier = RunPreflightBarrier()
        let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: manifestURL) }
        let host = SharedReadingHost(
            configuration: makeConfiguration(manifestURL: manifestURL),
            accounts: HoldingPreflightAccounts(events: events, barrier: barrier),
            peers: FakePeers(events: events),
            rendezvous: FakeRendezvous(events: events)
        )

        let first = Task {
            do {
                _ = try await host.runReport()
                return true
            } catch {
                return false
            }
        }
        await barrier.waitUntilEntered()
        let second = Task {
            do {
                _ = try await host.runReport()
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let entriesBeforeRelease = await barrier.entryCount
        await barrier.release()
        let outcomes = await [first.value, second.value]

        XCTAssertEqual(entriesBeforeRelease, 1)
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(outcomes.filter { !$0 }.count, 1)
        XCTAssertEqual(events.values.filter { $0 == "account:preflight" }.count, 1)
    }

    func testUnprovenCleanupTransfersPreparedLockWithoutRedundantJournalMutation() async throws {
        let events = EventRecorder()
        weak var releasedLock: FakeBuildLock?
        do {
            let lock = FakeBuildLock(events: events, releaseOnDeinitUnlessTransferred: true)
            releasedLock = lock
            let recorder = FakeBuildLockRecorder(events: events, failRecordAttempt: 2)
            let manifestURL = FileManager.default.temporaryDirectory.appendingPathComponent("rishi-host-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: manifestURL) }
            let host = try makeBoundPreparedHost(
                events: events,
                manifestURL: manifestURL,
                accounts: FakeAccounts(events: events, deleteErrorRole: .owner),
                recorder: recorder,
                acquireBuildLock: { lock }
            )

            let report = try await host.runReport()

            XCTAssertTrue(report.cleanupFailed)
            XCTAssertEqual(events.values.filter { $0 == "journal:record-lock" }.count, 1)
            XCTAssertTrue(events.values.contains("lock:transfer"))
        }
        XCTAssertNil(releasedLock)
        XCTAssertFalse(events.values.contains("lock:deinit-release"))
    }

    func testSetupContentionFinalizesAndRemovesEmptyJournalRunWithoutInvokingHostFactory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-cli-contention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        for attempt in 0..<2 {
            let runRoot = root.appendingPathComponent("rishi-shared-reading-\(attempt)", isDirectory: true)
            let journal = try SharedReadingRecoveryJournal(
                url: runRoot.appendingPathComponent("recovery.json"),
                runID: "run-\(attempt)"
            )
            var invokedHostFactory = false

            XCTAssertThrowsError(try SharedReadingHost.withPreparedBuildLockForHost(
                recoveryJournal: journal,
                prepare: { throw ResourcePreflightError("contention") },
                makeHost: { _ in
                    invokedHostFactory = true
                    throw ResourcePreflightError("host factory must not run")
                }
            ))
            XCTAssertFalse(invokedHostFactory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runRoot.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testConfigurationFailureReleasesPreparedLockAndRemovesProvenEmptyRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-cli-configuration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runRoot = root.appendingPathComponent("rishi-shared-reading-run", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(
            url: runRoot.appendingPathComponent("recovery.json"),
            runID: "run-configuration"
        )
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events)

        XCTAssertThrowsError(try SharedReadingHost.withPreparedBuildLockForHost(
            recoveryJournal: journal,
            prepare: {
                try SharedReadingHost.prepareBuildLock(
                    recorder: recorder,
                    acquire: { lock }
                )
            },
            makeHost: { _ in throw ResourcePreflightError("configuration") }
        ))

        XCTAssertEqual(events.values, [
            "journal:record-lock", "lock:release", "journal:clear-lock",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runRoot.path))
    }

    func testScopedFactoryRejectsDiscardedConsumingHostAndRollsBackExactOwnership() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-cli-discarded-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runRoot = root.appendingPathComponent("rishi-shared-reading-run", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(
            url: runRoot.appendingPathComponent("recovery.json"),
            runID: "run-discarded-host"
        )
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events)
        let manifestURL = runRoot.appendingPathComponent("manifest.json")

        XCTAssertThrowsError(try SharedReadingHost.withPreparedBuildLockForHost(
            recoveryJournal: journal,
            prepare: {
                try SharedReadingHost.prepareBuildLock(
                    recorder: recorder,
                    acquire: { lock }
                )
            },
            makeHost: { prepared in
                _ = try SharedReadingHost(
                    configuration: self.makeConfiguration(manifestURL: manifestURL),
                    accounts: FakeAccounts(events: events),
                    peers: FakePeers(events: events),
                    rendezvous: FakeRendezvous(events: events),
                    preparedBuildLock: prepared
                )
                return SharedReadingHost(
                    configuration: self.makeConfiguration(manifestURL: manifestURL),
                    accounts: FakeAccounts(events: events),
                    peers: FakePeers(events: events),
                    rendezvous: FakeRendezvous(events: events)
                )
            }
        ))

        XCTAssertEqual(Array(events.values.suffix(2)), ["lock:release", "journal:clear-lock"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runRoot.path))
    }

    func testEscapedConsumedHostIsInvalidAfterFactoryRollback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-cli-escaped-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runRoot = root.appendingPathComponent("rishi-shared-reading-run", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(
            url: runRoot.appendingPathComponent("recovery.json"),
            runID: "run-escaped-host"
        )
        let events = EventRecorder()
        let lock = FakeBuildLock(events: events)
        let recorder = FakeBuildLockRecorder(events: events)
        let manifestURL = runRoot.appendingPathComponent("manifest.json")
        var escapedHost: SharedReadingHost?

        XCTAssertThrowsError(try SharedReadingHost.withPreparedBuildLockForHost(
            recoveryJournal: journal,
            prepare: {
                try SharedReadingHost.prepareBuildLock(
                    recorder: recorder,
                    acquire: { lock }
                )
            },
            makeHost: { prepared in
                let consumedHost = try SharedReadingHost(
                    configuration: self.makeConfiguration(manifestURL: manifestURL),
                    accounts: FakeAccounts(events: events),
                    peers: FakePeers(events: events),
                    rendezvous: FakeRendezvous(events: events),
                    preparedBuildLock: prepared
                )
                escapedHost = consumedHost
                return SharedReadingHost(
                    configuration: self.makeConfiguration(manifestURL: manifestURL),
                    accounts: FakeAccounts(events: events),
                    peers: FakePeers(events: events),
                    rendezvous: FakeRendezvous(events: events)
                )
            }
        ))

        let capturedHost = try XCTUnwrap(escapedHost)
        let eventsAfterRollback = events.values
        do {
            _ = try await capturedHost.runReport()
            XCTFail("An escaped host report must remain invalid after exact lock rollback")
        } catch {
            XCTAssertTrue(error is ResourcePreflightError)
        }
        do {
            _ = try await capturedHost.run()
            XCTFail("An escaped host run must remain invalid after exact lock rollback")
        } catch {
            XCTAssertTrue(error is ResourcePreflightError)
        }

        XCTAssertEqual(events.values, eventsAfterRollback)
        XCTAssertEqual(eventsAfterRollback, [
            "journal:record-lock", "lock:release", "journal:clear-lock",
        ])
        XCTAssertFalse(events.values.contains("account:preflight"))
        XCTAssertFalse(events.values.contains("preflight"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runRoot.path))
    }

    func testPreparedBuildLockFactoryIsScopedAndReturnsOnlyTheConsumingHost() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("Sources/RishiE2EHost/SharedReadingHost.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("public static func prepareBuildLock("))
        XCTAssertFalse(source.contains("withPreparedBuildLockForHost<Output>"))
        XCTAssertTrue(source.contains("makeHost: (SharedReadingPreparedBuildLock) throws -> SharedReadingHost"))
        XCTAssertTrue(source.contains(") throws -> SharedReadingHost {"))
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

    private func makeHost(
        events: EventRecorder,
        manifestURL: URL,
        accounts: (any TestAccountManaging)? = nil,
        buildLockRecorder: any BuildLockOwnershipRecording,
        acquireBuildLock: @escaping @Sendable () throws -> any AppleXcodeBuildLockHolding
    ) -> SharedReadingHost {
        SharedReadingHost(
            configuration: makeConfiguration(manifestURL: manifestURL),
            accounts: accounts ?? FakeAccounts(events: events),
            peers: FakePeers(events: events),
            rendezvous: FakeRendezvous(events: events),
            buildLockRecorder: buildLockRecorder,
            acquireBuildLock: acquireBuildLock
        )
    }

    private func makeHost(
        preparedBuildLock: SharedReadingPreparedBuildLock,
        events: EventRecorder,
        manifestURL: URL
    ) throws -> SharedReadingHost {
        try SharedReadingHost(
            configuration: makeConfiguration(manifestURL: manifestURL),
            accounts: FakeAccounts(events: events),
            peers: FakePeers(events: events),
            rendezvous: FakeRendezvous(events: events),
            preparedBuildLock: preparedBuildLock
        )
    }

    private func makeBoundPreparedHost(
        events: EventRecorder,
        manifestURL: URL,
        accounts: (any TestAccountManaging)? = nil,
        recorder: any BuildLockOwnershipRecording,
        acquireBuildLock: @escaping @Sendable () throws -> any AppleXcodeBuildLockHolding
    ) throws -> SharedReadingHost {
        let recoveryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-host-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let journal = try SharedReadingRecoveryJournal(
            url: recoveryRoot
                .appendingPathComponent("run", isDirectory: true)
                .appendingPathComponent("recovery.json"),
            runID: "run-binding"
        )

        return try SharedReadingHost.withPreparedBuildLockForHost(
            recoveryJournal: journal,
            prepare: {
                try SharedReadingHost.prepareBuildLock(
                    recorder: recorder,
                    acquire: acquireBuildLock
                )
            },
            makeHost: { prepared in
                try SharedReadingHost(
                    configuration: self.makeConfiguration(manifestURL: manifestURL),
                    accounts: accounts ?? FakeAccounts(events: events),
                    peers: FakePeers(events: events),
                    rendezvous: FakeRendezvous(events: events),
                    preparedBuildLock: prepared
                )
            }
        )
    }

    private func makeConfiguration(manifestURL: URL) -> SharedReadingHost.Configuration {
        .init(
            runID: "run-build-lock",
            fixture: .init(role: .owner, format: .pdf, basename: "book.pdf", sha256: String(repeating: "d", count: 64), byteSize: 10),
            manifestURL: manifestURL,
            ownerDestination: .catalyst,
            participantDestination: .iPhone17Pro
        )
    }

    private final class FakeBuildLock: AppleXcodeBuildLockHolding, @unchecked Sendable {
        let ownership = AppleXcodeBuildLockOwnership(
            path: "/private/tmp/rishi-host-test.lock",
            token: "token",
            generation: "generation",
            owner: OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        )
        private let events: EventRecorder
        private let failRelease: Bool
        private let releaseOnDeinitUnlessTransferred: Bool
        private let stateLock = NSLock()
        private var transferred = false

        init(
            events: EventRecorder,
            failRelease: Bool = false,
            releaseOnDeinitUnlessTransferred: Bool = false
        ) {
            self.events = events
            self.failRelease = failRelease
            self.releaseOnDeinitUnlessTransferred = releaseOnDeinitUnlessTransferred
        }

        func release() throws {
            events.append("lock:release")
            if failRelease { throw ResourcePreflightError("release failed") }
        }

        func transferToRecovery() -> AppleXcodeBuildLockOwnership {
            events.append("lock:transfer")
            stateLock.withLock { transferred = true }
            return ownership
        }

        deinit {
            if releaseOnDeinitUnlessTransferred && !stateLock.withLock({ transferred }) {
                events.append("lock:deinit-release")
            }
        }
    }

    private final class FakeBuildLockRecorder: BuildLockOwnershipRecording, @unchecked Sendable {
        private let events: EventRecorder
        private let lock = NSLock()
        private var ownership: AppleXcodeBuildLockOwnership?
        private var shouldFailRecord: Bool
        private let failRecordAttempt: Int?
        private var recordAttempt = 0

        init(
            events: EventRecorder,
            failFirstRecord: Bool = false,
            failRecordAttempt: Int? = nil
        ) {
            self.events = events
            self.shouldFailRecord = failFirstRecord
            self.failRecordAttempt = failRecordAttempt
        }

        var recordedOwnership: AppleXcodeBuildLockOwnership? {
            lock.withLock { ownership }
        }

        func recordBuildLock(_ ownership: AppleXcodeBuildLockOwnership) throws {
            events.append("journal:record-lock")
            try lock.withLock {
                recordAttempt += 1
                if shouldFailRecord {
                    shouldFailRecord = false
                    throw SharedReadingRecoveryJournalError.journalRemovalFailed
                }
                if recordAttempt == failRecordAttempt {
                    throw SharedReadingRecoveryJournalError.journalRemovalFailed
                }
                guard self.ownership == nil || self.ownership == ownership else {
                    throw SharedReadingRecoveryJournalError.conflictingBuildLock
                }
                self.ownership = ownership
            }
        }

        func recordVerifiedBuildLockRelease(_ ownership: AppleXcodeBuildLockOwnership) throws {
            events.append("journal:clear-lock")
            try lock.withLock {
                guard self.ownership == ownership else {
                    throw SharedReadingRecoveryJournalError.missingRecordedBuildLock
                }
                self.ownership = nil
            }
        }
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

    private actor RunPreflightBarrier {
        private var entries = 0
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        var entryCount: Int { entries }

        func enterAndWait() async {
            entries += 1
            let waiters = entryWaiters
            entryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilEntered() async {
            guard entries == 0 else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private struct HoldingPreflightAccounts: TestAccountManaging {
        let events: EventRecorder
        let barrier: RunPreflightBarrier

        func preflight() async throws {
            events.append("account:preflight")
            await barrier.enterAndWait()
        }

        func create(role: TestAccountRole) async throws -> TestAccount {
            TestAccount(
                role: role,
                email: "\(role.rawValue)@example.test",
                password: "pw",
                userID: role.rawValue,
                bearerToken: "token"
            )
        }

        func waitForBookUpload(_ account: TestAccount, expectedSHA256: String, timeout: Duration) async throws {}
        func delete(_ account: TestAccount) async throws {}
        func verifyDeleted(_ account: TestAccount) async throws {}
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

    private final class CapturingProcessRunner: @unchecked Sendable, ProcessRunner {
        private let lock = NSLock()
        private var remaining: [ProcessResult]
        private var captured: [ProcessRequest] = []
        init(results: [ProcessResult]) { remaining = results }
        var requests: [ProcessRequest] { lock.withLock { captured } }
        func start(_ request: ProcessRequest) throws -> any ProcessHandle {
            try lock.withLock {
                captured.append(request)
                guard !remaining.isEmpty else { throw ResourcePreflightError("unexpected process") }
                return ImmediateProcessHandle(result: remaining.removeFirst())
            }
        }
    }

    private struct ImmediateProcessHandle: ProcessHandle {
        let result: ProcessResult
        func wait() async throws -> ProcessResult { result }
        func cancel() {}
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }
}
