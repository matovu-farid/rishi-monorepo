import Foundation
import XCTest
@testable import RishiE2EHost

final class ProcessRunnerTests: XCTestCase {
    func testRunnerPipeFactoryCreatesCloseOnExecDescriptors() throws {
        let flags = try FoundationProcessRunner.pipeDescriptorFlagsForTesting()

        XCTAssertEqual(flags.count, 2)
        XCTAssertTrue(flags.allSatisfy { $0 & FD_CLOEXEC != 0 })
    }

    func testFoundationRunnerSerializesPipeCreationAndSpawnSections() {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            FoundationProcessRunner.withSpawnLockForTesting {
                firstEntered.signal()
                releaseFirst.wait()
            }
            firstFinished.signal()
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            FoundationProcessRunner.withSpawnLockForTesting { secondEntered.signal() }
            secondFinished.signal()
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + .milliseconds(100)), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 1), .success)
    }

    func testStableIdentityRequiresIdentityAndProcessGroupRecheck() {
        let first = OwnedProcessIdentity(pid: 700, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let reused = OwnedProcessIdentity(pid: 700, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let identities = SequencedValues([first, reused])

        let result = OwnedProcessGroupInspector.stableIdentity(
            for: 700,
            in: 700,
            identity: { _ in identities.next() },
            processGroup: { _ in 700 }
        )

        XCTAssertNil(result)
    }

    func testStableIdentityRequiresProcessGroupToRemainUnchanged() {
        let identity = OwnedProcessIdentity(pid: 701, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let groups = SequencedValues<Int32?>([701, 999])

        let result = OwnedProcessGroupInspector.stableIdentity(
            for: 701,
            in: 701,
            identity: { _ in identity },
            processGroup: { _ in groups.next() }
        )

        XCTAssertNil(result)
    }

    func testOwnedAbsenceIncludesRecordedIdentityThatLeftGroup() throws {
        let escaped = OwnedProcessIdentity(pid: 702, birthTimeSeconds: 1, birthTimeMicroseconds: 2)

        let absent = try OwnedProcessGroupInspector.allOwnedProcessesAreAbsent(
            processGroupID: 700,
            observed: [escaped],
            members: { _ in [] },
            liveIdentity: { pid in pid == escaped.pid ? escaped : nil }
        )

        XCTAssertFalse(absent)
    }

    func testOwnedAbsenceFailsClosedWhenGroupEnumerationIsUnavailable() {
        XCTAssertThrowsError(try OwnedProcessGroupInspector.allOwnedProcessesAreAbsent(
            processGroupID: 700,
            observed: [],
            members: { _ in throw ProcessInspectionTestError.unavailable },
            liveIdentity: { _ in nil }
        ))
    }

    func testGateEOFExitsWithStatus125WithoutExecutingRequestedChild() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }

        let status = try FoundationProcessRunner.gateEOFExitStatusForTesting(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "touch \"$1\"", "rishi-e2e-test", marker.path]
        ))

        XCTAssertEqual(status, 125)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testProcessIdentityReaderUsesPIDAndBirthTime() throws {
        let identity = try XCTUnwrap(ProcessIdentityReader.identity(for: getpid()))

        XCTAssertEqual(identity.pid, getpid())
        XCTAssertGreaterThan(identity.birthTimeSeconds, 0)
    }

    func testFoundationRunnerRecordsStableRootAndDescendantIdentities() async throws {
        let recorder = ProcessRecorder()
        let handle = try FoundationProcessRunner(recorder: recorder).start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 0.2 & wait"]
        ))

        _ = try await handle.wait()

        XCTAssertEqual(recorder.groups.count, 1)
        XCTAssertGreaterThanOrEqual(recorder.processes.count, 2)
        XCTAssertEqual(recorder.groups[0].leader, recorder.processes[0])
    }

    func testSpawnCreatesPrivateGroupBeforeGateRelease() async throws {
        let recorder = ProcessRecorder()
        let result = try await FoundationProcessRunner(recorder: recorder).run(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$$\""]
        ))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(Int32(result.stdout), recorder.groups.single?.processGroupID)
        XCTAssertEqual(recorder.groups.single?.leader, recorder.processes.single)
    }

    func testJournalFailureBeforeGateReleasePreventsChildSideEffect() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }

        XCTAssertThrowsError(try FoundationProcessRunner(recorder: ProcessRecorder(failGroup: true)).start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "touch \"$1\"", "rishi-e2e-test", marker.path]
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testParentClosingGateBeforeReleaseMakesShellExitWithoutChildSideEffect() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }

        XCTAssertThrowsError(try FoundationProcessRunner(closeGateBeforeReleaseForTesting: true).start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "touch \"$1\"", "rishi-e2e-test", marker.path]
        )))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDescendantRecorderFailureCleansUpAndWaitThrows() async throws {
        let recorder = ProcessRecorder(failAfterProcessCount: 1)
        let handle = try FoundationProcessRunner(recorder: recorder).start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 2 & wait"]
        ))

        do {
            _ = try await handle.wait()
            XCTFail("Expected descendant recording failure")
        } catch {
            XCTAssertFalse(recorder.processes.isEmpty)
        }
    }

    func testFoundationRunnerCapturesOutputAndExitStatus() async throws {
        let recorder = ProcessRecorder()
        let handle = try FoundationProcessRunner(recorder: recorder).start(ProcessRequest(
            executablePath: "/usr/bin/printf",
            arguments: ["host-output"]
        ))

        let result = try await handle.wait()

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdout, "host-output")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testCancelledProcessCleansUpOwnedDescendants() async throws {
        let recorder = ProcessRecorder()
        let handle = try FoundationProcessRunner(recorder: recorder).start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 2"]
        ))

        try await Task.sleep(for: .milliseconds(100))
        let group = try XCTUnwrap(recorder.groups.single)
        XCTAssertEqual(ProcessIdentityReader.identity(for: group.leader.pid), group.leader)
        XCTAssertTrue(try OwnedProcessGroupInspector.members(in: group.processGroupID).contains(group.leader.pid))
        let clock = ContinuousClock()
        let started = clock.now
        handle.cancel()
        _ = try await handle.wait()
        XCTAssertLessThan(clock.now - started, .seconds(1))
    }
}

private final class ProcessRecorder: OwnedProcessRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storedGroups: [OwnedProcessGroup] = []
    private var storedProcesses: [OwnedProcessIdentity] = []
    private let failGroup: Bool
    private let failAfterProcessCount: Int?

    init(failGroup: Bool = false, failAfterProcessCount: Int? = nil) {
        self.failGroup = failGroup
        self.failAfterProcessCount = failAfterProcessCount
    }

    var groups: [OwnedProcessGroup] { lock.withLock { storedGroups } }
    var processes: [OwnedProcessIdentity] { lock.withLock { storedProcesses } }

    func recordOwnedProcessGroup(_ group: OwnedProcessGroup) throws {
        if failGroup { throw ProcessRecorderError.failed }
        lock.withLock { storedGroups.append(group) }
    }

    func recordOwnedProcess(_ identity: OwnedProcessIdentity) throws {
        try lock.withLock {
            if let failAfterProcessCount, storedProcesses.count >= failAfterProcessCount {
                throw ProcessRecorderError.failed
            }
            storedProcesses.append(identity)
        }
    }

    func recordOwnedSimulatorDevice(_: OwnedSimulatorDevice) throws {}
    func recordCatalystLaunchIntent(_: PendingCatalystLaunch) throws {}
    func recordCatalystRegisteredIdentity(_: OwnedProcessIdentity, role _: TestAccountRole, kind _: PendingCatalystLaunch.Kind) throws {}
}

private enum ProcessRecorderError: Error { case failed }
private enum ProcessInspectionTestError: Error { case unavailable }

private final class SequencedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]

    init(_ values: [Value]) { self.values = values }
    func next() -> Value { lock.withLock { values.removeFirst() } }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
