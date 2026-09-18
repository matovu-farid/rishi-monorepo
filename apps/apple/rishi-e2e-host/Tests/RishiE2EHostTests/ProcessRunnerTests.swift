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

        DispatchQueue.global().async {
            FoundationProcessRunner.withSpawnLockForTesting {
                firstEntered.signal()
                releaseFirst.wait()
            }
            firstFinished.signal()
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(FoundationProcessRunner.trySpawnLockForTesting())
        releaseFirst.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(FoundationProcessRunner.trySpawnLockForTesting())
    }

    func testWaitDrainsValidatedMonitorPublicationBeforeSuccessfulAbsence() async throws {
        let root = OwnedProcessIdentity(pid: 740, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let descendant = OwnedProcessIdentity(pid: 741, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let group = OwnedProcessGroup(processGroupID: root.pid, leader: root)
        let recorder = ProcessRecorder()
        try recorder.recordOwnedProcess(root)
        try recorder.recordOwnedProcessGroup(group)
        let state = MonitorCompletionRaceState(root: root, descendant: descendant)
        let stdout = Pipe()
        let stderr = Pipe()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        let waitCompleted = DispatchSemaphore(value: 0)
        let testHandle = FoundationProcessRunner.makeHandleForTesting(
            group: group,
            observed: [root],
            recorder: recorder,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            liveIdentity: { state.identity(for: $0) },
            members: { state.members(in: $0) },
            processGroup: { state.processGroup(of: $0) },
            signal: { state.signal(pid: $0, signal: $1) },
            observeRootExit: { _ in 0 },
            reapRoot: { state.reapRoot(pid: $0) },
            waitCallStarted: {},
            afterMonitorValidation: { state.pauseAfterValidation($0) },
            finalAbsenceAttemptStarted: { state.finalAbsenceAttemptStarted.signal() }
        )

        XCTAssertEqual(state.callbackValidated.wait(timeout: .now() + 1), .success)
        let wait = Task {
            defer { waitCompleted.signal() }
            return try await testHandle.handle.wait()
        }
        XCTAssertEqual(state.finalAbsenceAttemptStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(waitCompleted.wait(timeout: .now() + .milliseconds(100)), .timedOut)

        state.allowPublication.signal()
        XCTAssertTrue(recorder.waitForProcessCount(2, timeout: .now() + 1))
        testHandle.handle.cancel()
        _ = try await wait.value

        XCTAssertEqual(state.signals(for: descendant.pid), [SIGTERM])
        XCTAssertNil(state.identity(for: descendant.pid))
        XCTAssertEqual(recorder.processes, [root, descendant])
        XCTAssertTrue(testHandle.cleanupState().ownedProcessesAreAbsent)
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

    func testCleanupSignalsEscapedObservedDescendantWhenLeaderPIDWasReused() async throws {
        let originalLeader = OwnedProcessIdentity(pid: 720, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let reusedLeader = OwnedProcessIdentity(pid: 720, birthTimeSeconds: 3, birthTimeMicroseconds: 4)
        let escapedDescendant = OwnedProcessIdentity(pid: 721, birthTimeSeconds: 5, birthTimeMicroseconds: 6)
        let stdout = Pipe()
        let stderr = Pipe()
        let state = CleanupProcessState(
            identities: [reusedLeader.pid: reusedLeader, escapedDescendant.pid: escapedDescendant],
            descendant: escapedDescendant,
            writers: [stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = await FoundationProcessRunner.runCleanupPathForTesting(
            group: OwnedProcessGroup(processGroupID: originalLeader.pid, leader: originalLeader),
            observed: [originalLeader, escapedDescendant],
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            liveIdentity: { state.identity(for: $0) },
            members: { _ in [] },
            processGroup: { _ in nil },
            signal: { state.signal(pid: $0, signal: $1) },
            waitForRoot: { _ in 0 }
        )

        XCTAssertLessThan(clock.now - started, .seconds(1))
        XCTAssertTrue(result.waitThrewCleanupError)
        XCTAssertTrue(result.ownedProcessesAreAbsent)
        XCTAssertTrue(result.readersFinished)
        XCTAssertEqual(state.signals(for: escapedDescendant.pid), [SIGTERM, SIGKILL])
        XCTAssertTrue(state.signals(for: -originalLeader.pid).isEmpty)
        XCTAssertTrue(state.signals(for: reusedLeader.pid).isEmpty)
        XCTAssertNil(state.identity(for: escapedDescendant.pid))
        XCTAssertTrue(state.writersWereClosed)
    }

    func testInheritedWriterTimeoutFailsClosedAndFinishesReaders() async throws {
        let root = OwnedProcessIdentity(pid: 730, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let group = OwnedProcessGroup(processGroupID: root.pid, leader: root)
        let recorder = ProcessRecorder()
        try recorder.recordOwnedProcess(root)
        try recorder.recordOwnedProcessGroup(group)
        let stdout = Pipe()
        let stderr = Pipe()
        defer {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        let testHandle = FoundationProcessRunner.makeHandleForTesting(
            group: group,
            observed: [root],
            recorder: recorder,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            liveIdentity: { _ in nil },
            members: { _ in [] },
            processGroup: { _ in nil },
            signal: { _, _ in XCTFail("No process should be signalled"); return -1 },
            observeRootExit: { _ in 0 },
            reapRoot: { _ in },
            waitCallStarted: {}
        )
        let started = ContinuousClock.now

        do {
            _ = try await testHandle.handle.wait()
            XCTFail("Expected inherited writer timeout to fail closed")
        } catch is ProcessCleanupError {
            // Expected: ownership remains recorded because cleanup is unproven.
        }

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertTrue(testHandle.cleanupState().readersFinished)
        XCTAssertEqual(recorder.processes, [root])
        XCTAssertEqual(recorder.groups, [group])
    }

    func testConcurrentWaitsShareExitObservationCleanupAndSingleReap() async throws {
        let root = OwnedProcessIdentity(pid: 731, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let group = OwnedProcessGroup(processGroupID: root.pid, leader: root)
        let state = ConcurrentWaitState(root: root)
        let stdout = Pipe()
        let stderr = Pipe()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        let testHandle = FoundationProcessRunner.makeHandleForTesting(
            group: group,
            observed: [root],
            recorder: ProcessRecorder(),
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            liveIdentity: { state.identity(for: $0) },
            members: { state.members(in: $0) },
            processGroup: { state.processGroup(of: $0) },
            signal: { state.signal(pid: $0, signal: $1) },
            observeRootExit: { state.observeRootExit(pid: $0) },
            reapRoot: { try state.reapRoot(pid: $0) },
            waitCallStarted: { state.waitCallStarted() }
        )

        let first = Task { try await testHandle.handle.wait() }
        XCTAssertEqual(state.exitObservationStarted.wait(timeout: .now() + 1), .success)
        let second = Task { try await testHandle.handle.wait() }
        XCTAssertEqual(state.waitCallsReachedTwo.wait(timeout: .now() + 1), .success)
        state.allowExitObservation.signal()
        state.allowExitObservation.signal()
        let firstResult = try await first.value
        let secondResult = try await second.value

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(state.exitObservationCount, 1)
        XCTAssertEqual(state.reapCount, 1)
        XCTAssertTrue(state.checkedRootGroupBeforeReap)
        XCTAssertTrue(state.signals.isEmpty)
    }

    func testConcurrentWaitsShareInheritedWriterFailure() async throws {
        let root = OwnedProcessIdentity(pid: 732, birthTimeSeconds: 1, birthTimeMicroseconds: 2)
        let group = OwnedProcessGroup(processGroupID: root.pid, leader: root)
        let state = ConcurrentWaitState(root: root)
        let stdout = Pipe()
        let stderr = Pipe()
        defer {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        let testHandle = FoundationProcessRunner.makeHandleForTesting(
            group: group,
            observed: [root],
            recorder: ProcessRecorder(),
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            liveIdentity: { _ in nil },
            members: { _ in [] },
            processGroup: { _ in nil },
            signal: { _, _ in XCTFail("No process should be signalled"); return -1 },
            observeRootExit: { state.observeRootExit(pid: $0) },
            reapRoot: { try state.reapRoot(pid: $0) },
            waitCallStarted: { state.waitCallStarted() }
        )

        let first = Task { await cleanupErrorFromWait(testHandle.handle) }
        XCTAssertEqual(state.exitObservationStarted.wait(timeout: .now() + 1), .success)
        let second = Task { await cleanupErrorFromWait(testHandle.handle) }
        XCTAssertEqual(state.waitCallsReachedTwo.wait(timeout: .now() + 1), .success)
        state.allowExitObservation.signal()
        state.allowExitObservation.signal()

        let firstFailedClosed = await first.value
        let secondFailedClosed = await second.value
        XCTAssertTrue(firstFailedClosed)
        XCTAssertTrue(secondFailedClosed)
        XCTAssertEqual(state.exitObservationCount, 1)
        XCTAssertEqual(state.reapCount, 1)
        XCTAssertTrue(testHandle.cleanupState().readersFinished)
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
        let release = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(mkfifo(release.path, S_IRUSR | S_IWUSR), 0)
        defer { try? FileManager.default.removeItem(at: release) }
        let recorder = ProcessRecorder()
        let handle = try FoundationProcessRunner(recorder: recorder).start(ProcessRequest(
            executablePath: "/bin/sh",
            arguments: ["-c", "IFS= read -r release < \"$1\" & wait", "rishi-e2e-test", release.path]
        ))

        let descendantObserved = recorder.waitForProcessCount(2, timeout: .now() + 1)
        let writer = FileHandle(forWritingAtPath: release.path)
        writer?.write(Data("go\n".utf8))
        try? writer?.close()
        _ = try await handle.wait()

        XCTAssertTrue(descendantObserved)
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
    private let processRecorded = DispatchSemaphore(value: 0)
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
        processRecorded.signal()
    }

    func waitForProcessCount(_ count: Int, timeout: DispatchTime) -> Bool {
        while processes.count < count {
            if processRecorded.wait(timeout: timeout) == .timedOut { return false }
        }
        return true
    }

    func recordOwnedSimulatorDevice(_: OwnedSimulatorDevice) throws {}
    func recordCatalystLaunchIntent(_: PendingCatalystLaunch) throws {}
    func recordCatalystRegisteredIdentity(_: OwnedProcessIdentity, role _: TestAccountRole, kind _: PendingCatalystLaunch.Kind) throws {}
}

private enum ProcessRecorderError: Error { case failed }
private enum ProcessInspectionTestError: Error { case unavailable }

private func cleanupErrorFromWait(_ handle: any ProcessHandle) async -> Bool {
    do {
        _ = try await handle.wait()
        return false
    } catch is ProcessCleanupError {
        return true
    } catch {
        return false
    }
}

private final class ConcurrentWaitState: @unchecked Sendable {
    let exitObservationStarted = DispatchSemaphore(value: 0)
    let allowExitObservation = DispatchSemaphore(value: 0)
    let waitCallsReachedTwo = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let root: OwnedProcessIdentity
    private var storedWaitCalls = 0
    private var storedExitObservations = 0
    private var storedReaps = 0
    private var storedCheckedBeforeReap = false
    private var storedSignals: [(Int32, Int32)] = []

    init(root: OwnedProcessIdentity) { self.root = root }

    func waitCallStarted() {
        let reachedTwo = lock.withLock { () -> Bool in
            storedWaitCalls += 1
            return storedWaitCalls == 2
        }
        if reachedTwo { waitCallsReachedTwo.signal() }
    }

    func observeRootExit(pid: pid_t) -> Int32 {
        XCTAssertEqual(pid, root.pid)
        lock.withLock { storedExitObservations += 1 }
        exitObservationStarted.signal()
        allowExitObservation.wait()
        return 0
    }

    func reapRoot(pid: pid_t) throws {
        XCTAssertEqual(pid, root.pid)
        lock.withLock { storedReaps += 1 }
    }

    func identity(for pid: Int32) -> OwnedProcessIdentity? {
        lock.withLock { storedReaps == 0 && pid == root.pid ? root : nil }
    }

    func members(in processGroupID: Int32) -> [Int32] {
        lock.withLock {
            guard processGroupID == root.pid, storedReaps == 0 else { return [] }
            storedCheckedBeforeReap = true
            return [root.pid]
        }
    }

    func processGroup(of pid: Int32) -> Int32? {
        lock.withLock { storedReaps == 0 && pid == root.pid ? root.pid : nil }
    }

    func signal(pid: Int32, signal: Int32) -> Int32 {
        lock.withLock { storedSignals.append((pid, signal)) }
        return 0
    }

    var exitObservationCount: Int { lock.withLock { storedExitObservations } }
    var reapCount: Int { lock.withLock { storedReaps } }
    var checkedRootGroupBeforeReap: Bool { lock.withLock { storedCheckedBeforeReap } }
    var signals: [(Int32, Int32)] { lock.withLock { storedSignals } }
}

private final class MonitorCompletionRaceState: @unchecked Sendable {
    let callbackValidated = DispatchSemaphore(value: 0)
    let allowPublication = DispatchSemaphore(value: 0)
    let finalAbsenceAttemptStarted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let root: OwnedProcessIdentity
    private let descendant: OwnedProcessIdentity
    private var descendantIsDetached = false
    private var descendantIsAlive = true
    private var validationPaused = false
    private var rootWasReaped = false
    private var recordedSignals: [(Int32, Int32)] = []

    init(root: OwnedProcessIdentity, descendant: OwnedProcessIdentity) {
        self.root = root
        self.descendant = descendant
    }

    func identity(for pid: Int32) -> OwnedProcessIdentity? {
        lock.withLock {
            if pid == root.pid { return rootWasReaped ? nil : root }
            if pid == descendant.pid { return descendantIsAlive ? descendant : nil }
            return nil
        }
    }

    func members(in processGroupID: Int32) -> [Int32] {
        lock.withLock {
            guard processGroupID == root.pid else { return [] }
            var result = rootWasReaped ? [] : [root.pid]
            if descendantIsAlive, !descendantIsDetached { result.append(descendant.pid) }
            return result
        }
    }

    func processGroup(of pid: Int32) -> Int32? {
        lock.withLock {
            if pid == root.pid { return rootWasReaped ? nil : root.pid }
            if pid == descendant.pid { return descendantIsAlive && !descendantIsDetached ? root.pid : nil }
            return nil
        }
    }

    func pauseAfterValidation(_ identity: OwnedProcessIdentity) {
        guard identity == descendant else { return }
        let shouldPause = lock.withLock { () -> Bool in
            guard !validationPaused else { return false }
            validationPaused = true
            descendantIsDetached = true
            return true
        }
        guard shouldPause else { return }
        callbackValidated.signal()
        allowPublication.wait()
    }

    func signal(pid: Int32, signal: Int32) -> Int32 {
        lock.withLock {
            recordedSignals.append((pid, signal))
            if pid == descendant.pid, signal == SIGTERM { descendantIsAlive = false }
        }
        return 0
    }

    func reapRoot(pid: Int32) {
        XCTAssertEqual(pid, root.pid)
        lock.withLock { rootWasReaped = true }
    }

    func signals(for pid: Int32) -> [Int32] {
        lock.withLock { recordedSignals.compactMap { $0.0 == pid ? $0.1 : nil } }
    }
}

private final class CleanupProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Int32: OwnedProcessIdentity]
    private var recordedSignals: [(Int32, Int32)] = []
    private let descendant: OwnedProcessIdentity
    private var writers: [FileHandle]
    private var closedWriters = false

    init(identities: [Int32: OwnedProcessIdentity], descendant: OwnedProcessIdentity, writers: [FileHandle]) {
        self.identities = identities
        self.descendant = descendant
        self.writers = writers
    }

    func identity(for pid: Int32) -> OwnedProcessIdentity? {
        lock.withLock { identities[pid] }
    }

    func signal(pid: Int32, signal: Int32) -> Int32 {
        lock.withLock {
            recordedSignals.append((pid, signal))
            if pid == descendant.pid, signal == SIGKILL {
                identities[pid] = nil
                writers.forEach { try? $0.close() }
                writers.removeAll()
                closedWriters = true
            }
        }
        return 0
    }

    func signals(for pid: Int32) -> [Int32] {
        lock.withLock { recordedSignals.compactMap { $0.0 == pid ? $0.1 : nil } }
    }

    var writersWereClosed: Bool { lock.withLock { closedWriters } }
}

private final class SequencedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]

    init(_ values: [Value]) { self.values = values }
    func next() -> Value { lock.withLock { values.removeFirst() } }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
