import Foundation
import Darwin

public struct ProcessRequest: Sendable, Equatable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environment: [String: String]

    public init(executablePath: String, arguments: [String] = [], workingDirectory: URL? = nil, environment: [String: String] = [:]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitStatus == 0 }
}

public protocol ProcessHandle: Sendable {
    func wait() async throws -> ProcessResult
    func cancel()
}

public protocol ProcessRunner: Sendable {
    func start(_ request: ProcessRequest) throws -> any ProcessHandle
}

public extension ProcessRunner {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await start(request).wait()
    }
}

/// PID plus kernel birth time is the only process identity used for ownership.
public enum ProcessIdentityReader {
    public static func identity(for pid: Int32) -> OwnedProcessIdentity? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard result == expected else { return nil }
        return OwnedProcessIdentity(
            pid: pid,
            birthTimeSeconds: UInt64(info.pbi_start_tvsec),
            birthTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }
}

/// Shared by the live runner and recovery. It deliberately does not discover
/// ownership from names, command lines, parents, or environments.
enum ProcessInspectionError: Error {
    case enumerationUnavailable
}

enum OwnedProcessGroupInspector {
    static func members(in processGroupID: Int32) throws -> [Int32] {
        // `proc_listallpids(nil, 0)` is not a reliable sizing probe on every
        // supported Darwin release. Keep an explicitly bounded inventory.
        var pids = [pid_t](repeating: 0, count: 16_384)
        let listed = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard listed > 0, listed < pids.count else {
            throw ProcessInspectionError.enumerationUnavailable
        }
        return pids.prefix(Int(listed)).compactMap { pid in
            getpgid(pid) == processGroupID ? Int32(pid) : nil
        }
    }

    static func processGroup(of pid: Int32) -> Int32? {
        let group = getpgid(pid)
        return group < 0 ? nil : group
    }

    static func stableIdentity(
        for pid: Int32,
        in processGroupID: Int32,
        identity: (Int32) -> OwnedProcessIdentity? = ProcessIdentityReader.identity,
        processGroup: (Int32) -> Int32? = processGroup(of:)
    ) -> OwnedProcessIdentity? {
        guard let first = identity(pid), processGroup(pid) == processGroupID,
              identity(pid) == first, processGroup(pid) == processGroupID else { return nil }
        return first
    }

    static func allOwnedProcessesAreAbsent(
        processGroupID: Int32,
        observed: Set<OwnedProcessIdentity>,
        members: (Int32) throws -> [Int32] = members(in:),
        liveIdentity: (Int32) -> OwnedProcessIdentity? = ProcessIdentityReader.identity
    ) throws -> Bool {
        guard try members(processGroupID).isEmpty else { return false }
        return !observed.contains { liveIdentity($0.pid) == $0 }
    }
}

public struct FoundationProcessRunner: ProcessRunner {
    private static let spawnLock = NSLock()
    private let recorder: any OwnedProcessRecording
    private let closeGateBeforeReleaseForTesting: Bool

    public init(recorder: any OwnedProcessRecording = NoopOwnedProcessRecorder()) {
        self.recorder = recorder
        closeGateBeforeReleaseForTesting = false
    }

    init(recorder: any OwnedProcessRecording = NoopOwnedProcessRecorder(), closeGateBeforeReleaseForTesting: Bool) {
        self.recorder = recorder
        self.closeGateBeforeReleaseForTesting = closeGateBeforeReleaseForTesting
    }

#if DEBUG
    struct CleanupPathResultForTesting: Sendable {
        let waitThrewCleanupError: Bool
        let ownedProcessesAreAbsent: Bool
        let readersFinished: Bool
    }

    struct HandleForTesting: Sendable {
        let handle: any ProcessHandle
        private let state: @Sendable () -> (ownedProcessesAreAbsent: Bool, readersFinished: Bool)

        fileprivate init(handle: FoundationProcessHandle) {
            self.handle = handle
            state = { handle.cleanupStateForTesting() }
        }

        func cleanupState() -> (ownedProcessesAreAbsent: Bool, readersFinished: Bool) { state() }
    }

    static func withSpawnLockForTesting(beforeLock: () -> Void = {}, body: () -> Void) {
        beforeLock()
        spawnLock.withLock(body)
    }

    static func pipeDescriptorFlagsForTesting() throws -> [Int32] {
        try spawnLock.withLock {
            let descriptors = try makeCloseOnExecPipe()
            defer { closeIfOpen(descriptors.0); closeIfOpen(descriptors.1) }
            return [fcntl(descriptors.0, F_GETFD), fcntl(descriptors.1, F_GETFD)]
        }
    }

    static func gateEOFExitStatusForTesting(_ request: ProcessRequest) throws -> Int32 {
        try spawnLock.withLock {
            try gateEOFExitStatusSerializedForTesting(request)
        }
    }

    private static func gateEOFExitStatusSerializedForTesting(_ request: ProcessRequest) throws -> Int32 {
        let gate = try makeCloseOnExecPipe()
        let stdout = try makeCloseOnExecPipe()
        let stderr = try makeCloseOnExecPipe()
        var child: pid_t = 0
        defer {
            closeIfOpen(gate.0); closeIfOpen(gate.1)
            closeIfOpen(stdout.0); closeIfOpen(stdout.1)
            closeIfOpen(stderr.0); closeIfOpen(stderr.1)
        }
        child = try spawnGateShell(request: request, gate: gate, stdout: stdout, stderr: stderr)
        closeIfOpen(gate.0)
        closeIfOpen(stdout.1)
        closeIfOpen(stderr.1)
        closeIfOpen(gate.1)
        var status: Int32 = 0
        while true {
            let result = waitpid(child, &status, 0)
            if result == child { return decodedExitStatus(status) }
            if result == -1, errno != EINTR { throw ProcessCleanupError() }
        }
    }

    static func runCleanupPathForTesting(
        group: OwnedProcessGroup,
        observed: Set<OwnedProcessIdentity>,
        stdout: FileHandle,
        stderr: FileHandle,
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        members: @escaping @Sendable (Int32) throws -> [Int32],
        processGroup: @escaping @Sendable (Int32) -> Int32?,
        signal: @escaping @Sendable (Int32, Int32) -> Int32,
        waitForRoot: @escaping @Sendable (pid_t) -> Int32
    ) async -> CleanupPathResultForTesting {
        let testHandle = makeHandleForTesting(
            group: group,
            observed: observed,
            recorder: NoopOwnedProcessRecorder(),
            stdout: stdout,
            stderr: stderr,
            liveIdentity: liveIdentity,
            members: members,
            processGroup: processGroup,
            signal: signal,
            observeRootExit: waitForRoot,
            reapRoot: { _ in },
            waitCallStarted: {}
        )
        testHandle.handle.cancel()
        let waitThrewCleanupError: Bool
        do {
            _ = try await testHandle.handle.wait()
            waitThrewCleanupError = false
        } catch {
            waitThrewCleanupError = error is ProcessCleanupError
        }
        let state = testHandle.cleanupState()
        return CleanupPathResultForTesting(
            waitThrewCleanupError: waitThrewCleanupError,
            ownedProcessesAreAbsent: state.ownedProcessesAreAbsent,
            readersFinished: state.readersFinished
        )
    }

    static func makeHandleForTesting(
        group: OwnedProcessGroup,
        observed: Set<OwnedProcessIdentity>,
        recorder: any OwnedProcessRecording,
        stdout: FileHandle,
        stderr: FileHandle,
        liveIdentity: @escaping @Sendable (Int32) -> OwnedProcessIdentity?,
        members: @escaping @Sendable (Int32) throws -> [Int32],
        processGroup: @escaping @Sendable (Int32) -> Int32?,
        signal: @escaping @Sendable (Int32, Int32) -> Int32,
        observeRootExit: @escaping @Sendable (pid_t) throws -> Int32,
        reapRoot: @escaping @Sendable (pid_t) throws -> Void,
        waitCallStarted: @escaping @Sendable () -> Void
    ) -> HandleForTesting {
        HandleForTesting(handle: FoundationProcessHandle(
            pid: group.leader.pid,
            group: group,
            recorder: recorder,
            stdout: stdout,
            stderr: stderr,
            system: FoundationProcessSystem(
                liveIdentity: liveIdentity,
                members: members,
                processGroup: processGroup,
                signal: signal,
                observeRootExit: observeRootExit,
                reapRoot: reapRoot,
                waitCallStarted: waitCallStarted
            ),
            initialObserved: observed
        ))
    }
#endif

    public func start(_ request: ProcessRequest) throws -> any ProcessHandle {
        try Self.spawnLock.withLock {
            try startSerialized(request)
        }
    }

    private func startSerialized(_ request: ProcessRequest) throws -> any ProcessHandle {
        let gate = try makeCloseOnExecPipe()
        var stdout: (Int32, Int32) = (-1, -1)
        var stderr: (Int32, Int32) = (-1, -1)
        var child: pid_t = 0
        var released = false
        defer {
            if !released {
                closeIfOpen(gate.0); closeIfOpen(gate.1)
                closeIfOpen(stdout.0); closeIfOpen(stdout.1)
                closeIfOpen(stderr.0); closeIfOpen(stderr.1)
                if child > 0 { reapUnreleasedGateChild(child) }
            }
        }
        stdout = try makeCloseOnExecPipe()
        stderr = try makeCloseOnExecPipe()
        child = try spawnGateShell(request: request, gate: gate, stdout: stdout, stderr: stderr)

        closeIfOpen(gate.0)
        closeIfOpen(stdout.1)
        closeIfOpen(stderr.1)
        let rootPID = Int32(child)
        guard getpgid(child) == child, let root = ProcessIdentityReader.identity(for: rootPID) else {
            throw ProcessCleanupError()
        }
        let group = OwnedProcessGroup(processGroupID: rootPID, leader: root)
        try recorder.recordOwnedProcess(root)
        try recorder.recordOwnedProcessGroup(group)

        let handle = FoundationProcessHandle(
            pid: child,
            group: group,
            recorder: recorder,
            stdout: FileHandle(fileDescriptor: stdout.0, closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: stderr.0, closeOnDealloc: true)
        )
        stdout.0 = -1
        stderr.0 = -1
        if closeGateBeforeReleaseForTesting {
            closeIfOpen(gate.1)
            throw ProcessCleanupError()
        }
        guard writeAll(gate.1, Data("go\n".utf8)) else { throw ProcessCleanupError() }
        closeIfOpen(gate.1)
        released = true
        return handle
    }
}

struct ProcessCleanupError: Error, LocalizedError, Sendable {
    var errorDescription: String? { "Owned XCTest process descendants could not be cleaned up." }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ data: Data) { lock.withLock { value = data } }
    func get() -> Data { lock.withLock { value } }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?
    func retain(_ error: Error) { lock.withLock { if value == nil { value = error } } }
    var hasError: Bool { lock.withLock { value != nil } }
}

private struct FoundationProcessSystem: Sendable {
    let liveIdentity: @Sendable (Int32) -> OwnedProcessIdentity?
    let members: @Sendable (Int32) throws -> [Int32]
    let processGroup: @Sendable (Int32) -> Int32?
    let signal: @Sendable (Int32, Int32) -> Int32
    let observeRootExit: @Sendable (pid_t) throws -> Int32
    let reapRoot: @Sendable (pid_t) throws -> Void
    let waitCallStarted: @Sendable () -> Void

    static let live = FoundationProcessSystem(
        liveIdentity: { ProcessIdentityReader.identity(for: $0) },
        members: { try OwnedProcessGroupInspector.members(in: $0) },
        processGroup: { OwnedProcessGroupInspector.processGroup(of: $0) },
        signal: { Darwin.kill($0, $1) },
        observeRootExit: { pid in
            // Keep the exited leader waitable so its PID cannot be reused while
            // descendants are inventoried and cleaned. The zombie is excluded
            // from live-membership checks and reaped exactly once afterwards.
            var info = siginfo_t()
            while true {
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 {
                    return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
                }
                if errno != EINTR { throw ProcessCleanupError() }
            }
        },
        reapRoot: { pid in
            var status: Int32 = 0
            while true {
                let result = Darwin.waitpid(pid, &status, 0)
                if result == pid { return }
                if result == -1, errno != EINTR { throw ProcessCleanupError() }
            }
        },
        waitCallStarted: {}
    )
}

private final class FoundationProcessHandle: ProcessHandle, @unchecked Sendable {
    private let pid: pid_t
    private let group: OwnedProcessGroup
    private let recorder: any OwnedProcessRecording
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let system: FoundationProcessSystem
    private let stdoutData = DataBox()
    private let stderrData = DataBox()
    private let readers = DispatchGroup()
    private let lifecycleLock = NSLock()
    private let recordingError = ErrorBox()
    private var monitor: DispatchSourceTimer?
    private var observed = Set<OwnedProcessIdentity>()
    private var completionTask: Task<ProcessResult, Error>?
    private var finished = false
    private var cancellationRequested = false
    private var rootExitObserved = false

    init(
        pid: pid_t,
        group: OwnedProcessGroup,
        recorder: any OwnedProcessRecording,
        stdout: FileHandle,
        stderr: FileHandle,
        system: FoundationProcessSystem = .live,
        initialObserved: Set<OwnedProcessIdentity>? = nil
    ) {
        self.pid = pid
        self.group = group
        self.recorder = recorder
        self.stdout = stdout
        self.stderr = stderr
        self.system = system
        observed = initialObserved ?? [group.leader]
        startReaders()
        startMonitor()
    }

    func wait() async throws -> ProcessResult {
        system.waitCallStarted()
        let completion = lifecycleLock.withLock { () -> Task<ProcessResult, Error> in
            if let completionTask { return completionTask }
            let task = Task.detached(priority: .utility) { try await self.performWait() }
            completionTask = task
            return task
        }
        return try await withTaskCancellationHandler(
            operation: { try await completion.value },
            onCancel: { self.cancel() }
        )
    }

    private func performWait() async throws -> ProcessResult {
        let status: Int32
        do {
            status = try await Task.detached(priority: .utility) {
                try self.system.observeRootExit(self.pid)
            }.value
            lifecycleLock.withLock { rootExitObserved = true }
        } catch {
            recordingError.retain(error)
            stopMonitor()
            closeReadHandles()
            _ = await waitForReaders()
            throw ProcessCleanupError()
        }
        let cleaned = await waitForGroupAbsence()
        stopMonitor()
        do {
            try system.reapRoot(pid)
        } catch {
            recordingError.retain(error)
        }
        if !cleaned {
            closeReadHandles()
        }
        var readersFinished = await waitForReaders()
        let inheritedWriterTimedOut = !readersFinished
        if inheritedWriterTimedOut {
            // An unobserved process may have detached before the first group
            // inventory and retained inherited output writers. Darwin has no
            // supported recursive fork-tracking primitive, so fail closed and
            // force our blocking readers to complete without clearing ownership.
            closeReadHandles()
            readersFinished = await waitForReaders()
        }
        if !cleaned || inheritedWriterTimedOut || !readersFinished || recordingError.hasError {
            throw ProcessCleanupError()
        }
        return ProcessResult(exitStatus: status, stdout: String(decoding: stdoutData.get(), as: UTF8.self), stderr: String(decoding: stderrData.get(), as: UTF8.self))
    }

    func cancel() {
        let shouldCancel = lifecycleLock.withLock { () -> Bool in
            guard !finished, !cancellationRequested else { return false }
            cancellationRequested = true
            return true
        }
        if shouldCancel {
            signalVerifiedGroup(SIGTERM)
            // XCTest may deliberately inherit SIGTERM as ignored. Escalate
            // while the root wait is still pending; waiting to reap first
            // would make the TERM→KILL bound ineffective in that case.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self, !self.lifecycleLock.withLock({ self.finished }) else { return }
                self.signalVerifiedGroup(SIGKILL)
            }
        }
    }

    private func startReaders() {
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.readers.leave() }
            self.stdoutData.set(Self.readPipe(self.stdout))
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.readers.leave() }
            self.stderrData.set(Self.readPipe(self.stderr))
        }
    }

    private func startMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.recordStableGroupMembers() }
        lifecycleLock.withLock { monitor = timer }
        timer.resume()
    }

    private func stopMonitor() {
        let timer = lifecycleLock.withLock { () -> DispatchSourceTimer? in
            finished = true
            defer { monitor = nil }
            return monitor
        }
        timer?.cancel()
    }

    private func recordStableGroupMembers() {
        guard !lifecycleLock.withLock({ finished }) else { return }
        let members: [Int32]
        do {
            members = try system.members(group.processGroupID)
        } catch {
            recordingError.retain(error)
            cancel()
            return
        }
        for pid in members {
            guard let identity = OwnedProcessGroupInspector.stableIdentity(
                for: pid,
                in: group.processGroupID,
                identity: system.liveIdentity,
                processGroup: system.processGroup
            ) else { continue }
            let shouldRecord = lifecycleLock.withLock { observed.insert(identity).inserted }
            guard shouldRecord else { continue }
            do {
                try recorder.recordOwnedProcess(identity)
            } catch {
                recordingError.retain(error)
                cancel()
            }
        }
    }

    private func waitForGroupAbsence() async -> Bool {
        let termDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < termDeadline {
            recordStableGroupMembers()
            if ownedProcessesAreAbsent() { return true }
            if recordingError.hasError { cancel() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        cancel()
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < killDeadline {
            signalVerifiedGroup(SIGKILL)
            if ownedProcessesAreAbsent() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ownedProcessesAreAbsent()
    }

    private func ownedProcessesAreAbsent() -> Bool {
        let state = lifecycleLock.withLock {
            (observed: self.observed, rootExitObserved: self.rootExitObserved)
        }
        let observed = state.rootExitObserved ? state.observed.subtracting([group.leader]) : state.observed
        do {
            return try OwnedProcessGroupInspector.allOwnedProcessesAreAbsent(
                processGroupID: group.processGroupID,
                observed: observed,
                members: { processGroupID in
                    let members = try self.system.members(processGroupID)
                    guard state.rootExitObserved else { return members }
                    return members.filter { $0 != self.pid }
                },
                liveIdentity: system.liveIdentity
            )
        } catch {
            recordingError.retain(error)
            return false
        }
    }

    private func signalVerifiedGroup(_ signal: Int32) {
        let rootExitObserved = lifecycleLock.withLock { self.rootExitObserved }
        let liveLeader = system.liveIdentity(group.leader.pid)
        let leaderWasReused = liveLeader != nil && liveLeader != group.leader
        if leaderWasReused {
            recordingError.retain(ProcessCleanupError())
        } else if OwnedProcessGroupInspector.stableIdentity(
            for: group.leader.pid,
            in: group.processGroupID,
            identity: system.liveIdentity,
            processGroup: system.processGroup
        ) == group.leader {
            // The live PGID leader still proves that this exact private group
            // belongs to us, so a group signal cannot target a reused PGID.
            let groupResult = system.signal(-group.processGroupID, signal)
            // Keep the root reaping path live even on a Darwin configuration
            // that rejects a negative-PGID signal despite accepting the exact
            // same child PID.
            if !rootExitObserved, system.liveIdentity(group.leader.pid) == group.leader {
                if system.signal(group.leader.pid, signal) != 0, groupResult != 0 {
                    recordingError.retain(ProcessCleanupError())
                }
            }
        } else {
            do {
                for pid in try system.members(group.processGroupID) {
                    guard let identity = OwnedProcessGroupInspector.stableIdentity(
                        for: pid,
                        in: group.processGroupID,
                        identity: system.liveIdentity,
                        processGroup: system.processGroup
                    ) else { continue }
                    signalExactIdentity(identity, signal: signal)
                }
            } catch {
                recordingError.retain(error)
            }
        }
        let observed = lifecycleLock.withLock { self.observed }
        for identity in observed where !rootExitObserved || identity != group.leader {
            signalExactIdentity(identity, signal: signal)
        }
    }

    private func signalExactIdentity(_ identity: OwnedProcessIdentity, signal: Int32) {
        // Darwin has no pidfd-style identity-bound signal operation: kill(2)
        // accepts only a PID. Full birth identity checks immediately before
        // each signal are therefore the strongest available Darwin primitive,
        // but they cannot make validation plus kill atomic.
        guard system.liveIdentity(identity.pid) == identity,
              system.liveIdentity(identity.pid) == identity else { return }
        if system.signal(identity.pid, signal) != 0,
           system.liveIdentity(identity.pid) == identity {
            recordingError.retain(ProcessCleanupError())
        }
    }

    private func waitForReaders(timeout: DispatchTimeInterval = .seconds(1)) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.readers.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    private func closeReadHandles() {
        try? stdout.close()
        try? stderr.close()
    }

#if DEBUG
    func cleanupStateForTesting() -> (ownedProcessesAreAbsent: Bool, readersFinished: Bool) {
        (
            ownedProcessesAreAbsent: ownedProcessesAreAbsent(),
            readersFinished: readers.wait(timeout: .now()) == .success
        )
    }
#endif

    private static func readPipe(_ handle: FileHandle, maxBytes: Int = 4 * 1_024 * 1_024) -> Data {
        var result = Data()
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { return result }
                if result.count < maxBytes { result.append(chunk.prefix(maxBytes - result.count)) }
            } catch {
                return result
            }
        }
    }
}

private func makeCloseOnExecPipe() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw ProcessCleanupError() }
    for index in descriptors.indices {
        if descriptors[index] <= STDERR_FILENO {
            let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard replacement >= 0 else {
                closeIfOpen(descriptors[0]); closeIfOpen(descriptors[1])
                throw ProcessCleanupError()
            }
            closeIfOpen(descriptors[index])
            descriptors[index] = replacement
        }
        guard fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) == 0 else {
            closeIfOpen(descriptors[0]); closeIfOpen(descriptors[1])
            throw ProcessCleanupError()
        }
    }
    return (descriptors[0], descriptors[1])
}

private func spawnGateShell(request: ProcessRequest, gate: (Int32, Int32), stdout: (Int32, Int32), stderr: (Int32, Int32)) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw ProcessCleanupError() }
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    func add(_ result: Int32) throws { guard result == 0 else { throw ProcessCleanupError() } }
    try add(posix_spawn_file_actions_adddup2(&actions, gate.0, STDIN_FILENO))
    try add(posix_spawn_file_actions_adddup2(&actions, stdout.1, STDOUT_FILENO))
    try add(posix_spawn_file_actions_adddup2(&actions, stderr.1, STDERR_FILENO))
    for descriptor in [gate.0, gate.1, stdout.0, stdout.1, stderr.0, stderr.1] where descriptor > STDERR_FILENO {
        try add(posix_spawn_file_actions_addclose(&actions, descriptor))
    }
    if let directory = request.workingDirectory { try add(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
    try add(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
    try add(posix_spawnattr_setpgroup(&attributes, 0))
    let arguments = ["/bin/sh", "-c", "IFS= read -r gate || exit 125; exec \"$@\"", "rishi-e2e-gate", request.executablePath] + request.arguments
    let environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, value in value }.map { "\($0.key)=\($0.value)" }
    var child: pid_t = 0
    let result = withCStringArray(arguments) { argv in
        withCStringArray(environment) { envp in posix_spawn(&child, "/bin/sh", &actions, &attributes, argv, envp) }
    }
    guard result == 0 else { throw ProcessCleanupError() }
    return child
}

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let values = strings.map { strdup($0) }
    defer { values.forEach { free($0) } }
    var terminated = values + [nil]
    return terminated.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}

private func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        guard var pointer = bytes.baseAddress else { return true }
        var remaining = bytes.count
        while remaining > 0 {
            let written = write(descriptor, pointer, remaining)
            if written < 0 { if errno == EINTR { continue }; return false }
            pointer = pointer.advanced(by: written)
            remaining -= written
        }
        return true
    }
}

private func reapUnreleasedGateChild(_ pid: pid_t) {
    let deadline = Date().addingTimeInterval(1)
    var status: Int32 = 0
    while Date() < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || result == -1 { return }
        usleep(10_000)
    }
    if ProcessIdentityReader.identity(for: pid) != nil { _ = kill(pid, SIGKILL) }
    _ = waitpid(pid, &status, 0)
}

private func closeIfOpen(_ descriptor: Int32) { if descriptor >= 0 { _ = close(descriptor) } }
private func decodedExitStatus(_ status: Int32) -> Int32 { let signal = status & 0x7f; return signal == 0 ? (status >> 8) & 0xff : 128 + signal }
