import Darwin
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

    func testJournalReloadsDiskStateBeforeInterleavedCrossInstanceMutations() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let first = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        let second = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        let process = OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)

        try first.recordProvisioningAddress("owner@example.test", role: .owner)
        try second.recordOwnedProcess(process)
        try first.recordSecretArtifact(relativePath: "secret.xctestrun")
        try second.recordProvisioningAddress("participant@example.test", role: .participant)

        let state = try readJSONState(at: url)
        XCTAssertEqual((state["accounts"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((state["processes"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((state["secretArtifactRelativePaths"] as? [String])?.sorted(), ["secret.xctestrun"])
    }

    func testJournalConcurrentInstancesPreserveEveryUniqueMutation() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let errors = ConcurrentErrorRecorder()
        let group = DispatchGroup()

        for index in 0..<80 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
                    try journal.recordOwnedProcess(OwnedProcessIdentity(
                        pid: Int32(index + 1),
                        birthTimeSeconds: UInt64(index),
                        birthTimeMicroseconds: UInt64(index)
                    ))
                } catch {
                    errors.append(error)
                }
            }
        }
        group.wait()

        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        let state = try readJSONState(at: url)
        XCTAssertEqual((state["processes"] as? [[String: Any]])?.count, 80)
    }

    func testJournalRejectsRunDirectorySwapBeforeMutationOrFinalization() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runDirectory = root.appendingPathComponent("rishi-shared-reading-run")
        let url = runDirectory.appendingPathComponent("recovery.json")
        let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        try journal.recordProvisioningAddress("owner@example.test", role: .owner)
        XCTAssertEqual(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root), url)

        let externalRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let sentinel = externalRoot.appendingPathComponent("recovery.json")
        let sentinelData = Data("{\"external\":true}".utf8)
        try sentinelData.write(to: sentinel)
        try FileManager.default.moveItem(at: runDirectory, to: root.appendingPathComponent("parked-run"))
        try FileManager.default.createSymbolicLink(at: runDirectory, withDestinationURL: externalRoot)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.unresolvedArtifact(in: root))
        XCTAssertThrowsError(try SharedReadingRecoveryJournal(url: url, runID: "run-1"))
        XCTAssertThrowsError(try journal.recordOwnedProcess(OwnedProcessIdentity(
            pid: 42,
            birthTimeSeconds: 1,
            birthTimeMicroseconds: 2
        )))
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    }

    func testJournalRejectsRunDirectorySwapBeforeFinalRemoval() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runDirectory = root.appendingPathComponent("rishi-shared-reading-run")
        let url = runDirectory.appendingPathComponent("recovery.json")
        let journal = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        try journal.recordProvisioningAddress("owner@example.test", role: .owner)
        try journal.recordVerifiedDeletion("owner@example.test")

        let externalRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let sentinel = externalRoot.appendingPathComponent("recovery.json")
        let sentinelData = Data("{\"external\":true}".utf8)
        try sentinelData.write(to: sentinel)
        try FileManager.default.moveItem(at: runDirectory, to: root.appendingPathComponent("parked-run"))
        try FileManager.default.createSymbolicLink(at: runDirectory, withDestinationURL: externalRoot)

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    }

    func testJournalEncodesLogicallyIdenticalSetStateAsIdenticalBytes() throws {
        let firstRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: firstRoot) }
        let secondRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let first = try SharedReadingRecoveryJournal(
            url: firstRoot.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        let second = try SharedReadingRecoveryJournal(
            url: secondRoot.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        let processes = [
            OwnedProcessIdentity(pid: 43, birthTimeSeconds: 3, birthTimeMicroseconds: 4),
            OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2),
        ]
        let groups = processes.map { OwnedProcessGroup(processGroupID: $0.pid, leader: $0) }
        let devices = [
            OwnedSimulatorDevice(udid: "simulator-b", name: "B", deviceTypeIdentifier: "type", runtimeIdentifier: "runtime"),
            OwnedSimulatorDevice(udid: "simulator-a", name: "A", deviceTypeIdentifier: "type", runtimeIdentifier: "runtime"),
        ]
        let launches = [
            PendingCatalystLaunch(role: .participant, kind: .app, bundleIdentifier: "bundle-b", baselineIdentities: [processes[0], processes[1]], registeredIdentity: nil),
            PendingCatalystLaunch(role: .owner, kind: .runner, bundleIdentifier: "bundle-a", baselineIdentities: [processes[1], processes[0]], registeredIdentity: processes[1]),
        ]

        for index in processes.indices {
            try first.recordOwnedProcess(processes[index])
            try first.recordOwnedProcessGroup(groups[index])
            try first.recordOwnedSimulatorDevice(devices[index])
            try first.recordCatalystLaunchIntent(launches[index])
            try first.recordSecretArtifact(relativePath: "secret-\(index).xctestrun")
        }
        for index in processes.indices.reversed() {
            try second.recordOwnedProcess(processes[index])
            try second.recordOwnedProcessGroup(groups[index])
            try second.recordOwnedSimulatorDevice(devices[index])
            try second.recordCatalystLaunchIntent(launches[index])
            try second.recordSecretArtifact(relativePath: "secret-\(index).xctestrun")
        }

        XCTAssertEqual(try Data(contentsOf: first.url), try Data(contentsOf: second.url))
    }

    func testJournalConcurrentReadersNeverObservePartialJSONDuringAtomicWrites() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SharedReadingRecoveryJournal(
            url: root.appendingPathComponent("rishi-shared-reading-run/recovery.json"),
            runID: "run-1"
        )
        try journal.recordProvisioningAddress("initial@example.test", role: .owner)
        let readerDone = DispatchSemaphore(value: 0)
        let writing = LockedBoolean(true)
        let errors = ConcurrentErrorRecorder()

        DispatchQueue.global().async {
            while writing.value {
                do {
                    let data = try Data(contentsOf: journal.url)
                    if !data.isEmpty {
                        _ = try JSONSerialization.jsonObject(with: data)
                    }
                } catch {
                    errors.append(error)
                }
            }
            readerDone.signal()
        }
        for index in 0..<256 {
            try journal.recordProvisioningAddress("writer-\(index)@example.test", role: .participant)
        }
        writing.value = false
        XCTAssertEqual(readerDone.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.values.isEmpty)
    }

    func testFinalizationLeavesRunDirectoryEmptyAndFinalizedInstanceCannotResurrectJournal() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runDirectory = root.appendingPathComponent("rishi-shared-reading-run")
        let url = runDirectory.appendingPathComponent("recovery.json")
        let first = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        let second = try SharedReadingRecoveryJournal(url: url, runID: "run-1")

        try first.recordProvisioningAddress("owner@example.test", role: .owner)
        try second.recordOwnedProcess(OwnedProcessIdentity(
            pid: 42,
            birthTimeSeconds: 1,
            birthTimeMicroseconds: 2
        ))
        let state = try readJSONState(at: url)
        XCTAssertEqual((state["accounts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((state["processes"] as? [[String: Any]])?.count, 1)

        try first.recordVerifiedDeletion("owner@example.test")
        try second.recordVerifiedProcessAbsence(OwnedProcessIdentity(
            pid: 42,
            birthTimeSeconds: 1,
            birthTimeMicroseconds: 2
        ))
        try first.finalizeAfterSuccessfulCleanup()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runDirectory.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try first.recordOwnedProcess(OwnedProcessIdentity(
            pid: 43,
            birthTimeSeconds: 3,
            birthTimeMicroseconds: 4
        )))
        XCTAssertThrowsError(try second.recordOwnedProcess(OwnedProcessIdentity(
            pid: 44,
            birthTimeSeconds: 5,
            birthTimeMicroseconds: 6
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOversizedSparseRecoveryArtifactFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, off_t(64 * 1_024 * 1_024)), 0)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal(url: url, runID: "run-1")) { error in
            XCTAssertEqual(error as? SharedReadingRecoveryJournalError, .malformedArtifact)
        }
    }

    func testJournalPersistentDescriptorsAreCloseOnExec() throws {
        let journal = try makeJournal()

        let flags = journal.descriptorFlagsForTesting()
        XCTAssertEqual(flags.count, 2)
        XCTAssertTrue(flags.allSatisfy { $0 & FD_CLOEXEC != 0 })
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

    private func readJSONState(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

private final class ConcurrentErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Error] = []

    var values: [Error] { lock.withLock { storedValues } }

    func append(_ error: Error) {
        lock.withLock { storedValues.append(error) }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
