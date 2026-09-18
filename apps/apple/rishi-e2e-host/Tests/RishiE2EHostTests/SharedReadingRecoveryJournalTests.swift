import Darwin
import Foundation
import XCTest
@testable import RishiE2EHost

final class SharedReadingRecoveryJournalTests: XCTestCase {
    func testRecoveryNeverSignalsReusedProcessIdentity() async throws {
        let recorded = OwnedProcessIdentity(pid: 701, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let reused = OwnedProcessIdentity(pid: 701, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let signals = SignalRecorder()

        try await SharedReadingRecoveryJournal.recoverProcesses(
            [recorded],
            liveIdentity: { _ in reused },
            signal: { pid, _ in signals.append(pid) },
            sleep: { _ in }
        )

        XCTAssertEqual(signals.values, [])
    }

    func testRecoverySignalsOnlyMatchingIdentityAndWaitsForAbsence() async throws {
        let process = OwnedProcessIdentity(pid: 702, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let state = RecoveryProcessState(identity: process, remainsAfterKill: false)

        try await SharedReadingRecoveryJournal.recoverProcesses(
            [process],
            liveIdentity: { _ in state.identity },
            signal: { _, signal in state.signal(signal) },
            sleep: { _ in }
        )

        XCTAssertEqual(state.signals, [SIGTERM])
        XCTAssertNil(state.identity)
    }

    func testRecoveryFailsWhenMatchingProcessCannotBeProvenAbsent() async throws {
        let process = OwnedProcessIdentity(pid: 703, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let state = RecoveryProcessState(identity: process, remainsAfterKill: true)

        do {
            try await SharedReadingRecoveryJournal.recoverProcesses(
                [process],
                liveIdentity: { _ in state.identity },
                signal: { _, signal in state.signal(signal) },
                sleep: { _ in }
            )
            XCTFail("Expected failed absence proof")
        } catch {
            XCTAssertEqual(state.signals, [SIGTERM, SIGKILL])
        }
    }

    func testUnprovenRecoveryRetainsJournalProcessRecord() async throws {
        let journal = try makeJournal()
        let process = OwnedProcessIdentity(pid: 707, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let state = RecoveryProcessState(identity: process, remainsAfterKill: true)
        try journal.recordOwnedProcess(process)

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recoverProcesses(
            [process],
            liveIdentity: { _ in state.identity },
            signal: { _, signal in state.signal(signal) },
            sleep: { _ in }
        ))

        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
    }

    func testRecoveryRefusesReusedGroupWhenLeaderIdentityDoesNotMatch() async throws {
        let leader = OwnedProcessIdentity(pid: 704, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let group = OwnedProcessGroup(processGroupID: 704, leader: leader)
        let signals = SignalRecorder()

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recoverProcessGroups(
            [group],
            liveIdentity: { _ in OwnedProcessIdentity(pid: 704, birthTimeSeconds: 9, birthTimeMicroseconds: 9) },
            members: { _ in [704] },
            processGroup: { _ in 704 },
            signal: { pid, _ in signals.append(pid) },
            sleep: { _ in }
        ))
        XCTAssertEqual(signals.values, [])
    }

    func testRecoveryFailsClosedWhenGroupEnumerationIsUnavailable() async throws {
        let leader = OwnedProcessIdentity(pid: 709, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let signals = SignalRecorder()

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recoverProcessGroups(
            [OwnedProcessGroup(processGroupID: 709, leader: leader)],
            liveIdentity: { _ in nil },
            members: { _ in throw RecoveryInspectionTestError.unavailable },
            processGroup: { _ in nil },
            signal: { pid, _ in signals.append(pid) },
            sleep: { _ in }
        ))

        XCTAssertEqual(signals.values, [])
    }

    func testRecoveryTreatsAlreadyAbsentGroupAsRecovered() async throws {
        let leader = OwnedProcessIdentity(pid: 710, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let signals = SignalRecorder()

        try await SharedReadingRecoveryJournal.recoverProcessGroups(
            [OwnedProcessGroup(processGroupID: 710, leader: leader)],
            liveIdentity: { _ in nil },
            members: { _ in [] },
            processGroup: { _ in nil },
            signal: { pid, _ in signals.append(pid) },
            sleep: { _ in }
        )

        XCTAssertEqual(signals.values, [])
    }

    func testRecoveryCleansOriginalGroupMembersAfterLeaderExits() async throws {
        let leader = OwnedProcessIdentity(pid: 705, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let child = OwnedProcessIdentity(pid: 706, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let state = GroupRecoveryState(identities: [706: child], group: 705)

        try await SharedReadingRecoveryJournal.recoverProcessGroups(
            [OwnedProcessGroup(processGroupID: 705, leader: leader)],
            liveIdentity: { pid in state.identity(for: pid) },
            members: { _ in state.members },
            processGroup: { pid in state.processGroup(for: pid) },
            signal: { pid, signal in state.signal(pid, signal: signal) },
            sleep: { _ in }
        )

        XCTAssertEqual(state.signals.count, 1)
        XCTAssertEqual(state.signals.first?.0, 706)
        XCTAssertEqual(state.signals.first?.1, SIGTERM)
    }

    func testCrashAfterGateReleaseRecoversIdentityBoundGroupBeforeDescendantJournal() async throws {
        let root = OwnedProcessIdentity(pid: 708, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let state = GroupRecoveryState(identities: [708: root], group: 708)

        try await SharedReadingRecoveryJournal.recoverProcessGroups(
            [OwnedProcessGroup(processGroupID: 708, leader: root)],
            liveIdentity: { pid in state.identity(for: pid) },
            members: { _ in state.members },
            processGroup: { pid in state.processGroup(for: pid) },
            signal: { pid, signal in state.signal(pid, signal: signal) },
            sleep: { _ in }
        )

        XCTAssertEqual(state.signals.count, 1)
        XCTAssertEqual(state.signals.first?.0, root.pid)
        XCTAssertEqual(state.signals.first?.1, SIGTERM)
    }

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

    func testObserverOpeningFinalizedRunDirectoryCannotRecreateJournal() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let creator = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        try creator.recordProvisioningAddress("owner@example.test", role: .owner)
        try creator.recordVerifiedDeletion("owner@example.test")
        try creator.finalizeAfterSuccessfulCleanup()

        let observer = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        XCTAssertThrowsError(try observer.recordOwnedProcess(OwnedProcessIdentity(
            pid: 42,
            birthTimeSeconds: 1,
            birthTimeMicroseconds: 2
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBlockedObserverDoesNotRecreateJournalAfterCreatorFinalizes() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let creator = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        try creator.recordProvisioningAddress("owner@example.test", role: .owner)
        try creator.recordVerifiedDeletion("owner@example.test")

        let observerOpenedRunDirectory = DispatchSemaphore(value: 0)
        let allowObserverToLock = DispatchSemaphore(value: 0)
        let observerFinished = DispatchSemaphore(value: 0)
        let initializationErrors = ConcurrentErrorRecorder()
        let mutationErrors = ConcurrentErrorRecorder()
        DispatchQueue.global().async {
            defer { observerFinished.signal() }
            do {
                let observer = try SharedReadingRecoveryJournal(
                    url: url,
                    runID: "run-1",
                    beforeInitialDirectoryLockForTesting: {
                        observerOpenedRunDirectory.signal()
                        allowObserverToLock.wait()
                    }
                )
                do {
                    try observer.recordOwnedProcess(OwnedProcessIdentity(
                        pid: 42,
                        birthTimeSeconds: 1,
                        birthTimeMicroseconds: 2
                    ))
                } catch {
                    mutationErrors.append(error)
                }
            } catch {
                initializationErrors.append(error)
            }
        }

        XCTAssertEqual(observerOpenedRunDirectory.wait(timeout: .now() + 5), .success)
        try creator.finalizeAfterSuccessfulCleanup()
        allowObserverToLock.signal()
        XCTAssertEqual(observerFinished.wait(timeout: .now() + 5), .success)

        XCTAssertTrue(initializationErrors.values.isEmpty, "\(initializationErrors.values)")
        XCTAssertEqual(mutationErrors.values.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testObserverLoadsCreatorJournalWhenCreatorWritesBeforeObserverLocks() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rishi-shared-reading-run/recovery.json")
        let creator = try SharedReadingRecoveryJournal(url: url, runID: "run-1")
        let observerOpenedRunDirectory = DispatchSemaphore(value: 0)
        let allowObserverToLock = DispatchSemaphore(value: 0)
        let observerFinished = DispatchSemaphore(value: 0)
        let errors = ConcurrentErrorRecorder()

        DispatchQueue.global().async {
            defer { observerFinished.signal() }
            do {
                let observer = try SharedReadingRecoveryJournal(
                    url: url,
                    runID: "run-1",
                    beforeInitialDirectoryLockForTesting: {
                        observerOpenedRunDirectory.signal()
                        allowObserverToLock.wait()
                    }
                )
                try observer.recordOwnedProcess(OwnedProcessIdentity(
                    pid: 42,
                    birthTimeSeconds: 1,
                    birthTimeMicroseconds: 2
                ))
            } catch {
                errors.append(error)
            }
        }

        XCTAssertEqual(observerOpenedRunDirectory.wait(timeout: .now() + 5), .success)
        try creator.recordProvisioningAddress("owner@example.test", role: .owner)
        allowObserverToLock.signal()
        XCTAssertEqual(observerFinished.wait(timeout: .now() + 5), .success)

        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        let state = try readJSONState(at: url)
        XCTAssertEqual((state["accounts"] as? [[String: Any]])?.map { $0["email"] as? String }, ["owner@example.test"])
        XCTAssertEqual((state["processes"] as? [[String: Any]])?.count, 1)
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
        let mismatches = [
            AppleXcodeBuildLockOwnership(
                path: "\(lock.path)-replacement",
                token: lock.token,
                generation: lock.generation,
                owner: lock.owner
            ),
            AppleXcodeBuildLockOwnership(
                path: lock.path,
                token: "token-2",
                generation: lock.generation,
                owner: lock.owner
            ),
            AppleXcodeBuildLockOwnership(
                path: lock.path,
                token: lock.token,
                generation: "generation-2",
                owner: lock.owner
            ),
            AppleXcodeBuildLockOwnership(
                path: lock.path,
                token: lock.token,
                generation: lock.generation,
                owner: OwnedProcessIdentity(pid: 43, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
            ),
        ]
        for mismatch in mismatches {
            XCTAssertThrowsError(try journal.recordVerifiedBuildLockRelease(mismatch))
        }
        XCTAssertThrowsError(try journal.finalizeAfterSuccessfulCleanup())
        try journal.recordVerifiedBuildLockRelease(lock)
        try journal.finalizeAfterSuccessfulCleanup()
    }

    func testBuildLockRecordingIsIdempotentAndRejectsDifferentUnresolvedOwnership() throws {
        let journal = try makeJournal()
        let original = AppleXcodeBuildLockOwnership(
            path: "/private/tmp/rishi-lock",
            token: "token-1",
            generation: "generation-1",
            owner: OwnedProcessIdentity(pid: 42, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        )
        let replacement = AppleXcodeBuildLockOwnership(
            path: original.path,
            token: "token-2",
            generation: "generation-2",
            owner: original.owner
        )

        try journal.recordBuildLock(original)
        try journal.recordBuildLock(original)
        XCTAssertThrowsError(try journal.recordBuildLock(replacement)) { error in
            XCTAssertEqual(error as? SharedReadingRecoveryJournalError, .conflictingBuildLock)
        }
        XCTAssertThrowsError(try journal.recordVerifiedBuildLockRelease(replacement))
        try journal.recordVerifiedBuildLockRelease(original)
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

    func testRecoveryParsesEarlyJournalAndBothLegacyManifestShapes() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)

        let journalURL = root
            .appendingPathComponent("rishi-shared-reading-run-journal", isDirectory: true)
            .appendingPathComponent("recovery.json")
        let journal = try SharedReadingRecoveryJournal(url: journalURL, runID: "run-journal")
        let process = OwnedProcessIdentity(pid: 801, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)
        try journal.recordOwnedProcess(process)
        let decodedJournal = try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
            at: journalURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation
        )
        XCTAssertFalse(decodedJournal.isLegacy)
        XCTAssertEqual(decodedJournal.runID, "run-journal")
        XCTAssertEqual(decodedJournal.processes, [process])
        XCTAssertEqual(decodedJournal.accounts.map(\.role), [.owner])

        let fixture = RealBookFixture.Manifest(
            role: .owner,
            format: .pdf,
            basename: "fixture.pdf",
            sha256: String(repeating: "a", count: 64),
            byteSize: 12
        )
        let rendezvousURL = root
            .appendingPathComponent("rishi-shared-reading-run-rendezvous", isDirectory: true)
            .appendingPathComponent("manifest.json")
        try writeJSON(
            RendezvousManifest(
                runID: "run-rendezvous",
                fixture: fixture,
                ownerEmail: "rishi-e2e-owner@example.test",
                participantEmail: "rishi-e2e-participant@example.test",
                ownerDestination: .catalyst,
                participantDestination: .iPhone17Pro,
                rendezvousPath: "invite.json"
            ),
            to: rendezvousURL
        )
        let rendezvous = try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
            at: rendezvousURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation
        )
        XCTAssertTrue(rendezvous.isLegacy)
        XCTAssertEqual(Set(rendezvous.accounts.map { $0.role.rawValue }), ["owner", "participant"])

        let persistedURL = root
            .appendingPathComponent("rishi-shared-reading-run-persisted", isDirectory: true)
            .appendingPathComponent("manifest.json")
        try writeJSONObject([
            "runID": "run-persisted",
            "owner": ["role": "owner", "email": "rishi-e2e-owner@example.test"],
            "participant": ["role": "participant", "email": "rishi-e2e-participant@example.test"],
            "fixture": ["role": "owner", "format": "pdf", "basename": "fixture.pdf", "sha256": String(repeating: "a", count: 64), "byteSize": 12],
            "manifestPath": "manifest.json",
            "ownerDestination": "catalyst",
            "participantDestination": "iPhone17Pro",
            "rendezvousPath": "invite.json",
        ], to: persistedURL)
        let persisted = try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
            at: persistedURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation
        )
        XCTAssertTrue(persisted.isLegacy)
        XCTAssertEqual(Set(persisted.accounts.map { $0.role.rawValue }), ["owner", "participant"])
    }

    func testRecoveryArtifactRejectsMalformedDuplicateSecretAndOutOfScopeData() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        var cases: [[String: Any]] = [
            ["runID": "", "accounts": [], "processGroups": [], "processes": [], "simulatorDevices": [], "pendingCatalystLaunches": [], "secretArtifactRelativePaths": []],
            recoveryStateJSONObject(runID: "run-invalid", accounts: [
                ["email": "rishi-e2e-one@example.test", "role": "owner", "outcome": "recoverable"],
                ["email": "rishi-e2e-two@example.test", "role": "owner", "outcome": "recoverable"],
            ]),
            recoveryStateJSONObject(runID: "run-invalid", accounts: [
                ["email": "other@example.test", "role": "owner", "outcome": "recoverable"],
            ]),
            recoveryStateJSONObject(runID: "run-invalid", secretPaths: ["../owner.xctestrun"]),
            recoveryStateJSONObject(runID: "run-invalid", secretPaths: ["unexpected.xctestrun"]),
            recoveryStateJSONObject(runID: "run-invalid", simulatorDevices: [[
                "udid": "sim-1", "name": "not-the-run", "deviceTypeIdentifier": recoveryDeviceType,
                "runtimeIdentifier": recoveryRuntime,
            ]]),
            recoveryStateJSONObject(runID: "run-invalid", simulatorDevices: [[
                "udid": "sim-1", "name": "rishi-e2e-run-invalid", "deviceTypeIdentifier": "wrong-device",
                "runtimeIdentifier": recoveryRuntime,
            ]]),
            recoveryStateJSONObject(runID: "run-invalid", simulatorDevices: [[
                "udid": "sim-1", "name": "rishi-e2e-run-invalid", "deviceTypeIdentifier": recoveryDeviceType,
                "runtimeIdentifier": "unconfigured-runtime",
            ]]),
            recoveryStateJSONObject(runID: "run-invalid", pendingLaunches: [[
                "role": "owner", "kind": "app", "bundleIdentifier": "unexpected.bundle",
                "baselineIdentities": [],
            ]]),
            recoveryStateJSONObject(runID: "run-invalid", pendingLaunches: [[
                "role": "owner", "kind": "unexpected-kind", "bundleIdentifier": "org.fidexa.rishi",
                "baselineIdentities": [],
            ]]),
            recoveryStateJSONObject(runID: "run-invalid", pendingLaunches: [[
                "role": "owner", "kind": "app", "bundleIdentifier": "org.fidexa.rishi",
                "baselineIdentities": [], "nonce": "must-not-persist",
            ]]),
        ]
        let identity: [String: Any] = ["pid": 901, "birthTimeSeconds": 1, "birthTimeMicroseconds": 2]
        var duplicateProcesses = recoveryStateJSONObject(runID: "run-invalid")
        duplicateProcesses["processes"] = [identity, identity]
        cases.append(duplicateProcesses)
        var wrongLock = recoveryStateJSONObject(runID: "run-invalid")
        wrongLock["buildLock"] = [
            "path": root.appendingPathComponent("other.lock").path,
            "token": "token", "generation": "generation", "owner": identity,
        ]
        cases.append(wrongLock)

        for (index, object) in cases.enumerated() {
            let runID = object["runID"] as? String ?? "missing-\(index)"
            let url = root
                .appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
                .appendingPathComponent("recovery.json")
            try writeJSONObject(object, to: url)
            XCTAssertThrowsError(try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
                at: url,
                temporaryRoot: root,
                configuredBuildLockURL: lockURL,
                validation: recoveryValidation
            ), "case \(index)")
        }

        let secretURL = root
            .appendingPathComponent("rishi-shared-reading-run-secret", isDirectory: true)
            .appendingPathComponent("manifest.json")
        try writeJSONObject([
            "runID": "run-secret",
            "owner": ["role": "owner", "email": "rishi-e2e-owner@example.test", "password": "must-not-parse"],
            "participant": ["role": "participant", "email": "rishi-e2e-participant@example.test"],
        ], to: secretURL)
        XCTAssertThrowsError(try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
            at: secretURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation
        ))

        let externalRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let externalURL = externalRoot
            .appendingPathComponent("rishi-shared-reading-run-external", isDirectory: true)
            .appendingPathComponent("recovery.json")
        try writeJSONObject(recoveryStateJSONObject(runID: "run-external"), to: externalURL)
        XCTAssertThrowsError(try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
            at: externalURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation
        ))
    }

    func testRecoveryAcceptsExactProductionSimulatorNameAndRejectsNearMatches() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        let runID = "run-simulator-contract"
        let exactName = SharedReadingOwnedResourceContract.disposableSimulatorName(runID: runID)

        for (index, name) in [exactName, exactName + "-iPhone 17 Pro", exactName + "-copy"].enumerated() {
            let artifactURL = root
                .appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
                .appendingPathComponent("recovery.json")
            try writeJSONObject(recoveryStateJSONObject(runID: runID, simulatorDevices: [[
                "udid": "sim-\(index)", "name": name,
                "deviceTypeIdentifier": recoveryDeviceType,
                "runtimeIdentifier": recoveryRuntime,
            ]]), to: artifactURL)

            if index == 0 {
                XCTAssertNoThrow(try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
                    at: artifactURL,
                    temporaryRoot: root,
                    configuredBuildLockURL: lockURL,
                    validation: recoveryValidation
                ))
            } else {
                XCTAssertThrowsError(try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
                    at: artifactURL,
                    temporaryRoot: root,
                    configuredBuildLockURL: lockURL,
                    validation: recoveryValidation
                ), "near-match simulator name \(name) must fail closed")
            }
        }
    }

    func testRecoveryStopsCommandGroupsBeforeDeletingDisposableSimulatorAndAccounts() async throws {
        let fixture = try makeOrchestrationFixture(includeGroup: true, includeProcess: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "group:stop:811")), try XCTUnwrap(events.values.firstIndex(of: "simulator:delete:simulator-1")))
        XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "simulator:absent:simulator-1")), try XCTUnwrap(events.values.firstIndex(of: "account:delete:owner")))
    }

    func testRecoveryStopsMatchingProcessesBeforeDeletingAccounts() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        XCTAssertEqual(events.values, [
            "process:stop:812",
            "process:absent:812",
            "simulator:delete:simulator-1",
            "simulator:absent:simulator-1",
            "account:delete:owner",
            "account:verified:owner",
            "account:delete:participant",
            "account:verified:participant",
            "lock:reconcile",
            "artifact:remove",
        ])
    }

    func testRecoveryAttemptsEveryProcessWhenOneCannotBeStopped() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = try SharedReadingRecoveryJournal(url: fixture.artifactURL, runID: "run-order")
        try journal.recordOwnedProcess(OwnedProcessIdentity(pid: 813, birthTimeSeconds: 5, birthTimeMicroseconds: 6))
        let events = RecoveryEventRecorder()

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(
                events: events,
                artifactURL: fixture.artifactURL,
                failing: ["process:812"]
            )
        ))

        XCTAssertTrue(events.values.contains("process:stop:812"))
        XCTAssertTrue(events.values.contains("process:stop:813"))
        XCTAssertTrue(events.values.contains("process:absent:813"))
        XCTAssertFalse(events.values.contains(where: { $0.hasPrefix("account:") }))
    }

    func testRecoveryEnumeratesIdentityBoundPrivateGroupBeforeIndividualProcessCleanup() async throws {
        let fixture = try makeOrchestrationFixture(includeGroup: true, includeProcess: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        XCTAssertLessThan(
            try XCTUnwrap(events.values.firstIndex(of: "group:absent:811")),
            try XCTUnwrap(events.values.firstIndex(of: "process:stop:812"))
        )
    }

    func testRecoveryDoesNotDeleteAccountsWhileProcessCleanupIsUnproven() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(
                events: events,
                artifactURL: fixture.artifactURL,
                failing: ["process:812"]
            )
        ))

        XCTAssertFalse(events.values.contains(where: { $0.hasPrefix("simulator:") }))
        XCTAssertFalse(events.values.contains(where: { $0.hasPrefix("account:") }))
        XCTAssertFalse(events.values.contains("lock:reconcile"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testRecoveryAttemptsSecondAccountAfterFirstDeletionFails() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(
                events: events,
                artifactURL: fixture.artifactURL,
                failing: ["account:owner"]
            )
        ))

        XCTAssertTrue(events.values.contains("account:delete:owner"))
        XCTAssertTrue(events.values.contains("account:delete:participant"))
        XCTAssertTrue(events.values.contains("account:verified:participant"))
        XCTAssertFalse(events.values.contains("lock:reconcile"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testRecoveryDeletesPendingProvisioningAddressUntilAbsenceIsAuthoritative() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactURL = root
            .appendingPathComponent("rishi-shared-reading-run-pending", isDirectory: true)
            .appendingPathComponent("recovery.json")
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(url: artifactURL, runID: "run-pending")
        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: artifactURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: artifactURL)
        )

        XCTAssertEqual(events.values, [
            "account:delete:owner", "account:verified:owner", "artifact:remove",
        ])
    }

    func testRecoveryReconcilesLockOnlyAfterProcessesAndAccountsAreAbsent() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        let lockIndex = try XCTUnwrap(events.values.firstIndex(of: "lock:reconcile"))
        XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "process:absent:812")), lockIndex)
        XCTAssertLessThan(try XCTUnwrap(events.values.firstIndex(of: "account:verified:participant")), lockIndex)
        XCTAssertLessThan(lockIndex, try XCTUnwrap(events.values.firstIndex(of: "artifact:remove")))
    }

    func testRecoveryRetainsArtifactAndLockOnAnyFailure() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        do {
            try await SharedReadingRecoveryJournal.recover(
                at: fixture.artifactURL,
                temporaryRoot: fixture.root,
                configuredBuildLockURL: fixture.lockURL,
                validation: recoveryValidation,
                operations: recoveryOperations(
                    events: events,
                    artifactURL: fixture.artifactURL,
                    failing: ["simulator"]
                )
            )
            XCTFail("Expected fail-closed recovery")
        } catch {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("rishi-e2e-owner@example.test"))
            XCTAssertFalse(description.contains("token-order"))
        }

        XCTAssertFalse(events.values.contains("lock:reconcile"))
        XCTAssertFalse(events.values.contains("artifact:remove"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testRecoveryRemovesArtifactOnlyAfterCompleteProof() async throws {
        let fixture = try makeOrchestrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        XCTAssertEqual(events.values.last, "artifact:remove")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.artifactURL.deletingLastPathComponent().path))
    }

    func testLegacyManifestFailsClosedWhileExactRunIDProcessOrConfiguredLockExists() async throws {
        for (index, processVisible, lockExists) in [(0, true, false), (1, false, true)] {
            let root = try makeTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let artifactURL = root
                .appendingPathComponent("rishi-shared-reading-run-legacy-\(index)", isDirectory: true)
                .appendingPathComponent("manifest.json")
            let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
            try writeJSONObject([
                "runID": "run-legacy-\(index)",
                "owner": ["role": "owner", "email": "rishi-e2e-owner@example.test"],
                "participant": ["role": "participant", "email": "rishi-e2e-participant@example.test"],
                "fixture": ["role": "owner", "format": "pdf", "basename": "fixture.pdf", "sha256": String(repeating: "a", count: 64), "byteSize": 12],
                "manifestPath": "manifest.json",
                "ownerDestination": "catalyst",
                "participantDestination": "iPhone17Pro",
                "rendezvousPath": "invite.json",
            ], to: artifactURL)
            let events = RecoveryEventRecorder()

            await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recover(
                at: artifactURL,
                temporaryRoot: root,
                configuredBuildLockURL: lockURL,
                validation: recoveryValidation,
                operations: recoveryOperations(
                    events: events,
                    artifactURL: artifactURL,
                    legacyProcessVisible: processVisible,
                    configuredLockExists: lockExists
                )
            ))

            XCTAssertFalse(events.values.contains(where: { $0.hasPrefix("account:") }))
            XCTAssertFalse(events.values.contains("artifact:remove"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
        }
    }

    func testProductionLegacyDiscoveryUnavailableBlocksAccountLockAndArtifactCleanup() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactURL = root
            .appendingPathComponent("rishi-shared-reading-run-legacy-unavailable", isDirectory: true)
            .appendingPathComponent("manifest.json")
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        try writeLegacyManifest(runID: "run-legacy-unavailable", to: artifactURL)
        let events = RecoveryEventRecorder()

        await XCTAssertThrowsErrorAsync(try await SharedReadingRecoveryJournal.recover(
            at: artifactURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation,
            operations: RecoveryOperations(
                recoverProcessGroup: { _ in },
                recoverProcess: { _ in },
                currentCatalystIdentities: { _ in [] },
                recoverSimulator: { _ in },
                removeSecretArtifact: { _ in },
                recoverAccount: { _ in events.append("account") },
                exactRunIDProcessIsVisible: SharedReadingRecoveryJournal.productionExactRunIDProcessIsVisible,
                configuredBuildLockExists: { _ in false },
                finalizeArtifactAndBuildLock: { _, _ in events.append("artifact") }
            )
        ))

        XCTAssertEqual(events.values, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    func testLegacyRecoveryCanSucceedWhenInjectedDiscoveryExplicitlyProvesAbsence() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactURL = root
            .appendingPathComponent("rishi-shared-reading-run-legacy-safe", isDirectory: true)
            .appendingPathComponent("manifest.json")
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        try writeLegacyManifest(runID: "run-legacy-safe", to: artifactURL)
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: artifactURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: artifactURL)
        )

        XCTAssertTrue(events.values.contains("account:verified:owner"))
        XCTAssertTrue(events.values.contains("account:verified:participant"))
        XCTAssertTrue(events.values.contains("artifact:remove"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    func testFinalizationReconcilesLockThenRestoresExactArtifactWhenRunDirectoryRemovalFails() throws {
        let fixture = try makeFinalizationFixture(runID: "run-rmdir-failure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.artifactURL)
        let lockReconciled = LockedBoolean(false)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: fixture.lock,
            removeRunDirectory: { _, _ in throw RecoveryInspectionTestError.unavailable },
            syncRootAfterRemoval: { _ in },
            reconcileBuildLock: { _ in lockReconciled.value = true }
        ))

        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)
        XCTAssertTrue(lockReconciled.value)
    }

    func testFinalizationReconcilesLockThenRestoresExactArtifactWhenRootFsyncFailsAfterRmdir() throws {
        let fixture = try makeFinalizationFixture(runID: "run-fsync-failure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.artifactURL)
        let lockReconciled = LockedBoolean(false)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: fixture.lock,
            removeRunDirectory: { rootFD, name in
                guard unlinkat(rootFD, name, AT_REMOVEDIR) == 0 else {
                    throw RecoveryInspectionTestError.unavailable
                }
            },
            syncRootAfterRemoval: { _ in throw RecoveryInspectionTestError.unavailable },
            reconcileBuildLock: { _ in lockReconciled.value = true }
        ))

        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)
        XCTAssertTrue(lockReconciled.value)
    }

    func testCrashAfterLockReconciliationRetainsArtifactAndRetryFinishesWithAbsentLock() throws {
        let fixture = try makeFinalizationFixture(runID: "run-post-lock-crash")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.artifactURL)
        let reconciliationAttempts = LockedCounter()
        let shouldCrash = LockedBoolean(true)
        let lockPresent = LockedBoolean(true)
        let artifactWasPresentAtReconciliation = LockedBoolean(false)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: fixture.lock,
            afterBuildLockReconciliation: {
                if shouldCrash.value {
                    shouldCrash.value = false
                    throw RecoveryInspectionTestError.unavailable
                }
            },
            reconcileBuildLock: { _ in
                reconciliationAttempts.increment()
                artifactWasPresentAtReconciliation.value = FileManager.default.fileExists(
                    atPath: fixture.artifactURL.path
                )
                lockPresent.value = false
            }
        ))

        XCTAssertEqual(reconciliationAttempts.value, 1)
        XCTAssertTrue(artifactWasPresentAtReconciliation.value)
        XCTAssertFalse(lockPresent.value)
        XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), original)

        try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: fixture.lock,
            afterBuildLockReconciliation: {},
            reconcileBuildLock: { _ in
                reconciliationAttempts.increment()
                XCTAssertFalse(lockPresent.value, "Retry must observe idempotently absent retained lock")
            }
        )

        XCTAssertEqual(reconciliationAttempts.value, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.artifactURL.deletingLastPathComponent().path))
    }

    func testInterruptedRunRecoveryRemovesOwnedBuildAndResultTreesThenFinalizesRunDirectory() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "run-owned-trees"
        let runRoot = root.appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
        let artifactURL = runRoot.appendingPathComponent("recovery.json")
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(url: artifactURL, runID: runID)

        for role in [TestAccountRole.owner, .participant] {
            let relativePath = SharedReadingOwnedResourceContract.secretTestRunRelativePath(for: role)
            let secretURL = runRoot.appendingPathComponent(relativePath)
            try journal.recordSecretArtifact(relativePath: relativePath)
            try FileManager.default.createDirectory(at: secretURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("credential".utf8).write(to: secretURL)
            try Data("generated specification".utf8).write(
                to: secretURL.deletingLastPathComponent().appendingPathComponent("source.xctestrun")
            )
        }
        let objectURL = runRoot.appendingPathComponent("derived/catalyst/Build/Intermediates.noindex/App.build/object.o")
        try FileManager.default.createDirectory(at: objectURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2a, count: 4_096).write(to: objectURL)
        let resultURL = runRoot.appendingPathComponent("results/owner/result.xcresult/Data/Info.plist")
        try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("result".utf8).write(to: resultURL)
        try Data(#"{"runID":"run-owned-trees","redacted":true}"#.utf8).write(
            to: runRoot.appendingPathComponent("manifest.json")
        )

        try await SharedReadingRecoveryJournal.recover(
            at: artifactURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation,
            operations: productionFileCleanupOperations(artifactURL: artifactURL, temporaryRoot: root)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: runRoot.path))
    }

    func testFinalizationRejectsNearNameInsteadOfTreatingItAsOwnedManifest() throws {
        let fixture = try makeFinalizationFixture(runID: "run-manifest-near-name")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nearName = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent("manifest.json.backup")
        let data = Data("retain".utf8)
        try data.write(to: nearName)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: nil
        ))

        XCTAssertEqual(try Data(contentsOf: nearName), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testFinalizationRejectsSymlinkedManifestAndLeavesExternalTargetUntouched() throws {
        let fixture = try makeFinalizationFixture(runID: "run-manifest-symlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external-manifest")
        let externalData = Data("external".utf8)
        try externalData.write(to: external)
        let manifest = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: external)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: nil
        ))

        XCTAssertEqual(try Data(contentsOf: external), externalData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testFinalizationRejectsSpecialFileAtManifestPath() throws {
        let fixture = try makeFinalizationFixture(runID: "run-manifest-special")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        XCTAssertEqual(mkfifo(manifest.path, mode_t(S_IRUSR | S_IWUSR)), 0)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: nil
        ))

        var details = stat()
        XCTAssertEqual(lstat(manifest.path, &details), 0)
        XCTAssertEqual(details.st_mode & S_IFMT, S_IFIFO)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testFinalizationRejectsManifestInodeReplacementAfterValidation() throws {
        let fixture = try makeFinalizationFixture(runID: "run-manifest-replacement")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try original.write(to: manifest)
        let parked = fixture.root.appendingPathComponent("parked-manifest")
        let replacementAttempted = LockedBoolean(false)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: fixture.lock,
            afterBuildLockReconciliation: {
                try FileManager.default.moveItem(at: manifest, to: parked)
                try replacement.write(to: manifest)
                replacementAttempted.value = true
            },
            reconcileBuildLock: { _ in }
        ))

        XCTAssertTrue(replacementAttempted.value)
        XCTAssertEqual(try Data(contentsOf: manifest), replacement)
        XCTAssertEqual(try Data(contentsOf: parked), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testOwnedTreeRemovalRejectsSymlinkAndLeavesExternalTargetUntouched() throws {
        let fixture = try makeFinalizationFixture(runID: "run-tree-symlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runRoot = fixture.artifactURL.deletingLastPathComponent()
        let external = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("sentinel")
        let sentinelData = Data("external".utf8)
        try sentinelData.write(to: sentinel)
        let derived = runRoot.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: derived.appendingPathComponent("redirect"), withDestinationURL: external)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: nil
        ))

        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testOwnedTreeRemovalRejectsSpecialFileAndRetainsRecoveryArtifact() throws {
        let fixture = try makeFinalizationFixture(runID: "run-tree-special")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let results = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let fifo = results.appendingPathComponent("unexpected.fifo")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)), 0)

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: nil
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
        var details = stat()
        XCTAssertEqual(lstat(fifo.path, &details), 0)
        XCTAssertEqual(details.st_mode & S_IFMT, S_IFIFO)
    }

    func testOwnedTreeRemovalRejectsExternalHardlinkAndRetainsRecoveryArtifact() throws {
        let fixture = try makeFinalizationFixture(runID: "run-tree-hardlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external-file")
        let sentinelData = Data("must survive".utf8)
        try sentinelData.write(to: external)
        let results = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: external, to: results.appendingPathComponent("linked-result"))

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            buildLock: nil
        ))

        XCTAssertEqual(try Data(contentsOf: external), sentinelData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.artifactURL.path))
    }

    func testRecoveryPublicAPIHasExactProductionSignature() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/RishiE2EHost/SharedReadingRecoveryJournal.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("public static func recover("))
        XCTAssertTrue(source.contains("accountClient: TestAccountClient"))
    }

    func testRecoveryHandlesRegisteredAndUnresolvedCatalystIntentsWithoutBundleWideSignalling() async throws {
        let fixture = try makeOrchestrationFixture(includeProcess: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = try SharedReadingRecoveryJournal(url: fixture.artifactURL, runID: "run-order")
        let registered = OwnedProcessIdentity(pid: 814, birthTimeSeconds: 7, birthTimeMicroseconds: 8)
        try journal.recordCatalystLaunchIntent(PendingCatalystLaunch(
            role: .owner,
            kind: .runner,
            bundleIdentifier: "org.fidexa.rishiUITests",
            baselineIdentities: [],
            registeredIdentity: nil
        ))
        try journal.recordCatalystRegisteredIdentity(registered, role: .owner, kind: .runner)
        try journal.recordCatalystLaunchIntent(PendingCatalystLaunch(
            role: .owner,
            kind: .app,
            bundleIdentifier: "org.fidexa.rishi",
            baselineIdentities: [],
            registeredIdentity: nil
        ))
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        XCTAssertTrue(events.values.contains("process:stop:814"))
        XCTAssertTrue(events.values.contains("process:absent:814"))
        XCTAssertTrue(events.values.contains("intent:inspect:org.fidexa.rishi"))
        XCTAssertFalse(events.values.contains("intent:signal:org.fidexa.rishi"))
    }

    func testRecoveryRemovesBothReservedSecretClonesBeforeAccounts() async throws {
        let fixture = try makeOrchestrationFixture(includeProcess: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let journal = try SharedReadingRecoveryJournal(url: fixture.artifactURL, runID: "run-order")
        let roles: [TestAccountRole] = [.owner, .participant]
        let paths = roles.map(SharedReadingOwnedResourceContract.secretTestRunRelativePath(for:))
        for path in paths {
            try journal.recordSecretArtifact(relativePath: path)
            let url = fixture.artifactURL.deletingLastPathComponent().appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: url)
        }
        let events = RecoveryEventRecorder()

        try await SharedReadingRecoveryJournal.recover(
            at: fixture.artifactURL,
            temporaryRoot: fixture.root,
            configuredBuildLockURL: fixture.lockURL,
            validation: recoveryValidation,
            operations: recoveryOperations(events: events, artifactURL: fixture.artifactURL)
        )

        let ownerSecret = try XCTUnwrap(events.values.firstIndex(of: "secret:remove:owner.xctestrun"))
        let participantSecret = try XCTUnwrap(events.values.firstIndex(of: "secret:remove:participant.xctestrun"))
        let account = try XCTUnwrap(events.values.firstIndex(of: "account:delete:owner"))
        XCTAssertLessThan(ownerSecret, account)
        XCTAssertLessThan(participantSecret, account)
    }

    func testProducerGeneratedSecretClonePathsDecodeThroughRecoveryContract() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "run-producer-contract"
        let runRoot = root.appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
        let artifactURL = runRoot.appendingPathComponent("recovery.json")
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(url: artifactURL, runID: runID)
        let manifest = HostRunManifest(
            runID: runID,
            owner: TestAccount(role: .owner, email: "rishi-e2e-owner@example.test", password: "pw", userID: "owner", bearerToken: "token"),
            participant: TestAccount(role: .participant, email: "rishi-e2e-participant@example.test", password: "pw", userID: "participant", bearerToken: "token"),
            fixture: .init(role: .owner, format: .epub, basename: "fixture.epub", sha256: String(repeating: "a", count: 64), byteSize: 1),
            ownerDestination: .catalyst,
            participantDestination: .iPhone17Pro,
            rendezvousPath: "invite.json"
        )
        let runner = XCTestPeerProcessRunner(
            configuration: .init(
                projectPath: URL(fileURLWithPath: "/private/tmp/rishi.xcodeproj"),
                simulatorID: "simulator",
                derivedDataRoot: runRoot.appendingPathComponent("derived", isDirectory: true),
                resultBundleRoot: runRoot.appendingPathComponent("results", isDirectory: true)
            ),
            recoveryJournal: journal
        )

        let roles: [TestAccountRole] = [.owner, .participant]
        for role in roles {
            let relativePath = SharedReadingOwnedResourceContract.secretTestRunRelativePath(for: role)
            let derivedData = runRoot.appendingPathComponent(relativePath, isDirectory: false)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            let source = products.appendingPathComponent("source.xctestrun")
            let plist: [String: Any] = ["UITests": ["TestBundlePath": "__TESTROOT__/rishiUITests.xctest"]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: source)

            let clone = try runner.makeRoleTestRunSpecification(
                role: role,
                derivedData: derivedData,
                manifest: manifest,
                inviteToken: role == .participant ? "invite" : nil
            )
            XCTAssertEqual(clone.standardizedFileURL.path, runRoot.appendingPathComponent(relativePath).standardizedFileURL.path)
        }

        let artifact = try SharedReadingRecoveryJournal.decodeRecoveryArtifact(
            at: artifactURL,
            temporaryRoot: root,
            configuredBuildLockURL: lockURL,
            validation: recoveryValidation
        )
        XCTAssertEqual(
            Set(artifact.secretArtifactURLs.map(\.standardizedFileURL.path)),
            Set(roles.map {
                runRoot.appendingPathComponent(SharedReadingOwnedResourceContract.secretTestRunRelativePath(for: $0)).standardizedFileURL.path
            })
        )
    }

    func testProductionSecretCloneRemovalIsRunRootAnchoredAndPrunesCanonicalDirectories() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runRoot = root.appendingPathComponent("rishi-shared-reading-run-secret-removal", isDirectory: true)
        let roles: [TestAccountRole] = [.owner, .participant]
        for role in roles {
            let url = runRoot.appendingPathComponent(
                SharedReadingOwnedResourceContract.secretTestRunRelativePath(for: role)
            )
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("credential".utf8).write(to: url)
            try SharedReadingRecoveryJournal.removeProductionSecretArtifact(at: url, runRoot: runRoot)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("derived").path))

        let interruptedURL = runRoot.appendingPathComponent(
            SharedReadingOwnedResourceContract.secretTestRunRelativePath(for: .owner)
        )
        try FileManager.default.createDirectory(
            at: interruptedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SharedReadingRecoveryJournal.removeProductionSecretArtifact(at: interruptedURL, runRoot: runRoot)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("derived").path),
            "retry after a post-unlink crash must prune the canonical empty directory chain"
        )

        let external = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalSecret = external.appendingPathComponent("owner.xctestrun")
        try Data("must survive".utf8).write(to: externalSecret)
        let derived = runRoot.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: derived.appendingPathComponent("catalyst"),
            withDestinationURL: external
        )
        let canonicalOwner = runRoot.appendingPathComponent(
            SharedReadingOwnedResourceContract.secretTestRunRelativePath(for: .owner)
        )

        XCTAssertThrowsError(try SharedReadingRecoveryJournal.removeProductionSecretArtifact(
            at: canonicalOwner,
            runRoot: runRoot
        ))
        XCTAssertEqual(try Data(contentsOf: externalSecret), Data("must survive".utf8))
    }

    private var recoveryRuntime: String { "com.apple.CoreSimulator.SimRuntime.iOS-26-0" }
    private var recoveryDeviceType: String { "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" }

    private var recoveryValidation: RecoveryArtifactValidation {
        RecoveryArtifactValidation(
            emailIsInConfiguredNamespace: {
                $0.hasPrefix("rishi-e2e-") && $0.hasSuffix("@example.test")
            },
            allowedRuntimeIdentifiers: [recoveryRuntime],
            runnerBundleIdentifier: "org.fidexa.rishiUITests",
            appBundleIdentifier: "org.fidexa.rishi"
        )
    }

    private struct OrchestrationFixture {
        let root: URL
        let artifactURL: URL
        let lockURL: URL
    }

    private struct FinalizationFixture {
        let root: URL
        let artifactURL: URL
        let lock: AppleXcodeBuildLockOwnership
    }

    private func makeFinalizationFixture(runID: String) throws -> FinalizationFixture {
        let root = try makeTemporaryRoot()
        let artifactURL = root
            .appendingPathComponent("rishi-shared-reading-\(runID)", isDirectory: true)
            .appendingPathComponent("recovery.json")
        let lock = AppleXcodeBuildLockOwnership(
            path: root.appendingPathComponent("build.lock").path,
            token: "token-\(runID)",
            generation: "generation-\(runID)",
            owner: OwnedProcessIdentity(pid: 899, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        )
        try writeJSONObject(recoveryStateJSONObject(runID: runID), to: artifactURL)
        return FinalizationFixture(root: root, artifactURL: artifactURL, lock: lock)
    }

    private func makeOrchestrationFixture(
        includeGroup: Bool = false,
        includeProcess: Bool = true
    ) throws -> OrchestrationFixture {
        let root = try makeTemporaryRoot()
        let artifactURL = root
            .appendingPathComponent("rishi-shared-reading-run-order", isDirectory: true)
            .appendingPathComponent("recovery.json")
        let lockURL = root.appendingPathComponent("build.lock", isDirectory: true)
        let journal = try SharedReadingRecoveryJournal(url: artifactURL, runID: "run-order")
        try journal.recordProvisioningAddress("rishi-e2e-owner@example.test", role: .owner)
        try journal.recordProvisioningOutcome(.recoverable, email: "rishi-e2e-owner@example.test")
        try journal.recordProvisioningAddress("rishi-e2e-participant@example.test", role: .participant)
        try journal.recordProvisioningOutcome(.recoverable, email: "rishi-e2e-participant@example.test")
        if includeGroup {
            let leader = OwnedProcessIdentity(pid: 811, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
            try journal.recordOwnedProcessGroup(OwnedProcessGroup(processGroupID: 811, leader: leader))
        }
        if includeProcess {
            try journal.recordOwnedProcess(OwnedProcessIdentity(pid: 812, birthTimeSeconds: 3, birthTimeMicroseconds: 4))
        }
        try journal.recordOwnedSimulatorDevice(OwnedSimulatorDevice(
            udid: "simulator-1",
            name: "rishi-e2e-run-order",
            deviceTypeIdentifier: recoveryDeviceType,
            runtimeIdentifier: recoveryRuntime
        ))
        try journal.recordBuildLock(AppleXcodeBuildLockOwnership(
            path: lockURL.path,
            token: "token-order",
            generation: "generation-order",
            owner: OwnedProcessIdentity(pid: 810, birthTimeSeconds: 1, birthTimeMicroseconds: 1)
        ))
        return OrchestrationFixture(root: root, artifactURL: artifactURL, lockURL: lockURL)
    }

    private func recoveryOperations(
        events: RecoveryEventRecorder,
        artifactURL: URL,
        failing: Set<String> = [],
        currentCatalystIdentities: [String: Set<OwnedProcessIdentity>] = [:],
        legacyProcessVisible: Bool = false,
        configuredLockExists: Bool = false
    ) -> RecoveryOperations {
        RecoveryOperations(
            recoverProcessGroup: { group in
                events.append("group:stop:\(group.processGroupID)")
                if failing.contains("group") { throw RecoveryInspectionTestError.unavailable }
                events.append("group:absent:\(group.processGroupID)")
            },
            recoverProcess: { process in
                events.append("process:stop:\(process.pid)")
                if failing.contains("process:\(process.pid)") { throw RecoveryInspectionTestError.unavailable }
                events.append("process:absent:\(process.pid)")
            },
            currentCatalystIdentities: { bundle in
                events.append("intent:inspect:\(bundle)")
                if failing.contains("bundle") { throw RecoveryInspectionTestError.unavailable }
                return currentCatalystIdentities[bundle] ?? []
            },
            recoverSimulator: { simulator in
                events.append("simulator:delete:\(simulator.udid ?? "intent")")
                if failing.contains("simulator") { throw RecoveryInspectionTestError.unavailable }
                events.append("simulator:absent:\(simulator.udid ?? "intent")")
            },
            removeSecretArtifact: { url in
                events.append("secret:remove:\(url.lastPathComponent)")
                if failing.contains("secret") { throw RecoveryInspectionTestError.unavailable }
            },
            recoverAccount: { account in
                events.append("account:delete:\(account.role.rawValue)")
                if failing.contains("account:\(account.role.rawValue)") { throw RecoveryInspectionTestError.unavailable }
                events.append("account:verified:\(account.role.rawValue)")
            },
            exactRunIDProcessIsVisible: { _ in legacyProcessVisible },
            configuredBuildLockExists: { _ in configuredLockExists },
            finalizeArtifactAndBuildLock: { _, buildLock in
                if failing.contains("artifact") { throw RecoveryInspectionTestError.unavailable }
                if buildLock != nil {
                    events.append("lock:reconcile")
                    if failing.contains("lock") { throw RecoveryInspectionTestError.unavailable }
                }
                events.append("artifact:remove")
                try FileManager.default.removeItem(at: artifactURL.deletingLastPathComponent())
            }
        )
    }

    private func productionFileCleanupOperations(
        artifactURL: URL,
        temporaryRoot: URL
    ) -> RecoveryOperations {
        let runRoot = artifactURL.deletingLastPathComponent()
        return RecoveryOperations(
            recoverProcessGroup: { _ in },
            recoverProcess: { _ in },
            currentCatalystIdentities: { _ in [] },
            recoverSimulator: { _ in },
            removeSecretArtifact: { url in
                try SharedReadingRecoveryJournal.removeProductionSecretArtifact(at: url, runRoot: runRoot)
            },
            recoverAccount: { _ in },
            exactRunIDProcessIsVisible: { _ in false },
            configuredBuildLockExists: { _ in false },
            finalizeArtifactAndBuildLock: { url, lock in
                try SharedReadingRecoveryJournal.finalizeProductionArtifactAndBuildLock(
                    at: url,
                    temporaryRoot: temporaryRoot,
                    buildLock: lock
                )
            }
        )
    }

    private func recoveryStateJSONObject(
        runID: String,
        accounts: [[String: Any]] = [],
        simulatorDevices: [[String: Any]] = [],
        pendingLaunches: [[String: Any]] = [],
        secretPaths: [String] = []
    ) -> [String: Any] {
        [
            "runID": runID,
            "accounts": accounts,
            "processGroups": [],
            "processes": [],
            "simulatorDevices": simulatorDevices,
            "pendingCatalystLaunches": pendingLaunches,
            "secretArtifactRelativePaths": secretPaths,
            "buildLock": NSNull(),
        ]
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url)
    }

    private func writeJSONObject(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private func writeLegacyManifest(runID: String, to url: URL) throws {
        try writeJSONObject([
            "runID": runID,
            "owner": ["role": "owner", "email": "rishi-e2e-owner@example.test"],
            "participant": ["role": "participant", "email": "rishi-e2e-participant@example.test"],
            "fixture": [
                "role": "owner", "format": "pdf", "basename": "fixture.pdf",
                "sha256": String(repeating: "a", count: 64), "byteSize": 12,
            ],
            "manifestPath": "manifest.json",
            "ownerDestination": "catalyst",
            "participantDestination": "iPhone17Pro",
            "rendezvousPath": "invite.json",
        ], to: url)
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }
    func increment() { lock.withLock { storedValue += 1 } }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int32] = []

    var values: [Int32] { lock.withLock { stored } }
    func append(_ pid: Int32) { lock.withLock { stored.append(pid) } }
}

private final class RecoveryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private enum RecoveryInspectionTestError: Error { case unavailable }

private final class RecoveryProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentity: OwnedProcessIdentity?
    private var storedSignals: [Int32] = []
    private let remainsAfterKill: Bool

    init(identity: OwnedProcessIdentity, remainsAfterKill: Bool) {
        storedIdentity = identity
        self.remainsAfterKill = remainsAfterKill
    }

    var identity: OwnedProcessIdentity? { lock.withLock { storedIdentity } }
    var signals: [Int32] { lock.withLock { storedSignals } }

    func signal(_ signal: Int32) {
        lock.withLock {
            storedSignals.append(signal)
            if !remainsAfterKill { storedIdentity = nil }
        }
    }
}

private final class GroupRecoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentities: [Int32: OwnedProcessIdentity]
    private let group: Int32
    private var storedSignals: [(Int32, Int32)] = []

    init(identities: [Int32: OwnedProcessIdentity], group: Int32) {
        storedIdentities = identities
        self.group = group
    }

    var members: [Int32] { lock.withLock { Array(storedIdentities.keys) } }
    var signals: [(Int32, Int32)] { lock.withLock { storedSignals } }
    func identity(for pid: Int32) -> OwnedProcessIdentity? { lock.withLock { storedIdentities[pid] } }
    func processGroup(for pid: Int32) -> Int32? { lock.withLock { storedIdentities[pid] == nil ? nil : group } }

    func signal(_ pid: Int32, signal: Int32) {
        lock.withLock {
            storedSignals.append((pid, signal))
            storedIdentities[pid] = nil
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
