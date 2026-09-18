import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingRecoveryJournalTests: XCTestCase {
    func testJournalPersistsOnlyRecoverySafeFieldsAtomically() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")

        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("rishi-e2e-owner@example.test"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("bearer"))
        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), url)
    }

    func testJournalRemovesAddressOnlyAfterVerifiedDeletion() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedDeletion("rishi-e2e-owner@example.test")
        try journal.finalizeAfterSuccessfulCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
    }

    func testUnresolvedArtifactFindsEarlyJournalBeforeLaterManifest() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlyURL = root.appendingPathComponent("rishi-shared-reading-a/recovery.json")
        let laterURL = root.appendingPathComponent("rishi-shared-reading-z/manifest.json")
        try writeArtifact(at: earlyURL)
        try writeArtifact(at: laterURL)

        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), earlyURL)
    }

    func testMalformedRecoveryArtifactFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: url)

        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), url)
        XCTAssertThrowsError(try SharedReadingRecoveryJournal(url: url, runID: "run-1"))
    }

    func testUnresolvedArtifactRejectsSymlinkedRunDirectoryWithoutTouchingExternalData() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let externalRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let externalArtifact = externalRoot.appendingPathComponent("recovery.json")
        let externalData = Data("{\"external\":true}".utf8)
        try externalData.write(to: externalArtifact)
        let symlink = root.appendingPathComponent("rishi-shared-reading-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: externalRoot)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root))
        XCTAssertEqual(try Data(contentsOf: externalArtifact), externalData)
    }

    func testUnresolvedArtifactRejectsSymlinkedCandidateWithoutTouchingExternalData() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let externalRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let externalArtifact = externalRoot.appendingPathComponent("outside.json")
        let externalData = Data("{\"external\":true}".utf8)
        try externalData.write(to: externalArtifact)
        let runRoot = root.appendingPathComponent("rishi-shared-reading-run")
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runRoot.appendingPathComponent("recovery.json"),
            withDestinationURL: externalArtifact
        )

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root))
        XCTAssertEqual(try Data(contentsOf: externalArtifact), externalData)
    }

    func testUnresolvedArtifactRejectsUnexpectedMatchingChildAndCandidateTypes() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("rishi-shared-reading-file"))

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root))

        let candidateRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: candidateRoot) }
        let runRoot = candidateRoot.appendingPathComponent("rishi-shared-reading-run")
        try FileManager.default.createDirectory(
            at: runRoot.appendingPathComponent("recovery.json"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.unresolvedArtifact(in: candidateRoot))
    }

    func testJournalUpdateNeverLeavesPartialJSON() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )

        for index in 0..<32 {
            try journal.recordProvisioningAddress("rishi-e2e-\(index)@example.test", role: .owner)
            let data = try Data(contentsOf: journal.url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["runID"] as? String, "run-1")
            XCTAssertNotNil(object?["accounts"] as? [[String: Any]])
        }
    }

    func testJournalFinalizesOnlyAfterExactVerifiedProcessGroupAbsence() throws {
        let journal = try makeJournal()
        let group = OwnedProcessGroup(
            processGroupID: 41,
            leader: OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        )
        try journal.recordOwnedProcessGroup(group)

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertThrowsError(try journal.recordVerifiedProcessGroupAbsence(OwnedProcessGroup(
            processGroupID: group.processGroupID,
            leader: OwnedProcessIdentity(pid: 42, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        )))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedProcessGroupAbsence(group)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalFinalizesOnlyAfterExactVerifiedProcessAbsence() throws {
        let journal = try makeJournal()
        let process = OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        try journal.recordOwnedProcess(process)

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertThrowsError(try journal.recordVerifiedProcessAbsence(OwnedProcessIdentity(
            pid: process.pid,
            birthTimeSeconds: 3,
            birthTimeMicroseconds: 4
        )))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedProcessAbsence(process)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalReplacesSimulatorIntentThenFinalizesOnlyAfterExactVerifiedDeletion() throws {
        let journal = try makeJournal()
        let intent = OwnedSimulatorDevice(
            udid: nil,
            name: "Rishi E2E",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
        )
        let realized = OwnedSimulatorDevice(
            udid: "simulator-1",
            name: intent.name,
            deviceTypeIdentifier: intent.deviceTypeIdentifier,
            runtimeIdentifier: intent.runtimeIdentifier
        )
        try journal.recordOwnedSimulatorDevice(intent)

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordRealizedSimulatorDevice(realized, replacingIntent: intent)
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertThrowsError(try journal.recordVerifiedSimulatorDeletion(OwnedSimulatorDevice(
            udid: "simulator-2",
            name: realized.name,
            deviceTypeIdentifier: realized.deviceTypeIdentifier,
            runtimeIdentifier: realized.runtimeIdentifier
        )))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedSimulatorDeletion(realized)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalFinalizesOnlyAfterExactVerifiedCatalystLaunchAbsence() throws {
        let journal = try makeJournal()
        let baseline = OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let registered = OwnedProcessIdentity(pid: 43, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let intent = PendingCatalystLaunch(
            role: .owner,
            kind: .app,
            bundleIdentifier: "com.example.rishi",
            baselineIdentities: [baseline],
            registeredIdentity: nil
        )
        let registeredIntent = PendingCatalystLaunch(
            role: intent.role,
            kind: intent.kind,
            bundleIdentifier: intent.bundleIdentifier,
            baselineIdentities: intent.baselineIdentities,
            registeredIdentity: registered
        )
        try journal.recordCatalystLaunchIntent(intent)
        try journal.recordCatalystRegisteredIdentity(registered, role: .owner, kind: .app)

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertThrowsError(try journal.recordVerifiedCatalystLaunchAbsence(PendingCatalystLaunch(
            role: registeredIntent.role,
            kind: registeredIntent.kind,
            bundleIdentifier: registeredIntent.bundleIdentifier,
            baselineIdentities: registeredIntent.baselineIdentities,
            registeredIdentity: OwnedProcessIdentity(pid: registered.pid, birthTimeSeconds: 5, birthTimeMicroseconds: 6)
        )))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedCatalystLaunchAbsence(registeredIntent)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalRejectsConflictingCatalystLaunchIntentAndRetainsOriginal() throws {
        let journal = try makeJournal()
        let original = PendingCatalystLaunch(
            role: .owner,
            kind: .runner,
            bundleIdentifier: "com.example.owner",
            baselineIdentities: [OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)],
            registeredIdentity: nil
        )
        let conflicting = PendingCatalystLaunch(
            role: original.role,
            kind: original.kind,
            bundleIdentifier: "com.example.other",
            baselineIdentities: original.baselineIdentities,
            registeredIdentity: nil
        )
        let registered = OwnedProcessIdentity(pid: 43, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let registeredOriginal = PendingCatalystLaunch(
            role: original.role,
            kind: original.kind,
            bundleIdentifier: original.bundleIdentifier,
            baselineIdentities: original.baselineIdentities,
            registeredIdentity: registered
        )
        try journal.recordCatalystLaunchIntent(original)
        try journal.recordCatalystLaunchIntent(original)

        XCTAssertThrowsError(try journal.recordCatalystLaunchIntent(conflicting))
        try journal.recordCatalystRegisteredIdentity(registered, role: original.role, kind: original.kind)
        XCTAssertThrowsError(try journal.recordVerifiedCatalystLaunchAbsence(original))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedCatalystLaunchAbsence(registeredOriginal)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalRefusesToRegisterAmbiguousPersistedCatalystLaunchesWithoutClearingEither() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let first = PendingCatalystLaunch(
            role: .owner,
            kind: .app,
            bundleIdentifier: "com.example.one",
            baselineIdentities: [],
            registeredIdentity: nil
        )
        let second = PendingCatalystLaunch(
            role: first.role,
            kind: first.kind,
            bundleIdentifier: "com.example.two",
            baselineIdentities: [],
            registeredIdentity: nil
        )
        try writeRecoveryState(at: url, pendingLaunches: [first, second])
        let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")

        XCTAssertThrowsError(try journal.recordCatalystRegisteredIdentity(
            OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2),
            role: .owner,
            kind: .app
        ))
        try journal.recordVerifiedCatalystLaunchAbsence(first)
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedCatalystLaunchAbsence(second)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalFinalizesOnlyAfterExactVerifiedSecretArtifactDeletion() throws {
        let journal = try makeJournal()
        try journal.recordSecretArtifact(relativePath: "credentials.xctestrun")

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertThrowsError(try journal.recordVerifiedSecretArtifactDeletion(relativePath: "other.xctestrun"))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedSecretArtifactDeletion(relativePath: "credentials.xctestrun")
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testJournalFinalizesOnlyAfterExactVerifiedBuildLockRelease() throws {
        let journal = try makeJournal()
        let lock = AppleXcodeBuildLockOwnership(
            path: "/private/tmp/rishi-lock",
            token: "token-1",
            generation: "generation-1",
            owner: OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        )
        try journal.recordBuildLock(lock)

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertThrowsError(try journal.recordVerifiedBuildLockRelease(AppleXcodeBuildLockOwnership(
            path: lock.path,
            token: lock.token,
            generation: "generation-2",
            owner: lock.owner
        )))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedBuildLockRelease(lock)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testPublicRecoveryValueInitializersConstructValues() {
        let process = OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let group = OwnedProcessGroup(processGroupID: 41, leader: process)
        let device = OwnedSimulatorDevice(
            udid: "simulator-1",
            name: "Rishi E2E",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
        )
        let launch = PendingCatalystLaunch(
            role: .owner,
            kind: .runner,
            bundleIdentifier: "com.example.rishi",
            baselineIdentities: [process],
            registeredIdentity: process
        )
        let lock = AppleXcodeBuildLockOwnership(
            path: "/private/tmp/rishi-lock",
            token: "token-1",
            generation: "generation-1",
            owner: process
        )

        XCTAssertEqual(group.leader, process)
        XCTAssertEqual(device.udid, "simulator-1")
        XCTAssertEqual(launch.kind, .runner)
        XCTAssertEqual(lock.owner, process)
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rishi-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeJournal() throws -> SharedReadingRecoveryJournal {
        let root = try makeTemporaryRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
    }

    private func writeArtifact(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }

    private func writeRecoveryState(at url: URL, pendingLaunches: [PendingCatalystLaunch]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let launchData = try encoder.encode(pendingLaunches)
        let launches = try JSONSerialization.jsonObject(with: launchData)
        let state: [String: Any] = [
            "runID": "run-1",
            "accounts": [],
            "processGroups": [],
            "processes": [],
            "simulatorDevices": [],
            "pendingCatalystLaunches": launches,
            "secretArtifactRelativePaths": [],
            "buildLock": NSNull(),
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url)
    }
}
