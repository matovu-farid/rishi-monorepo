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
enum OwnedProcessGroupInspector {
    static func members(in processGroupID: Int32) -> [Int32] {
        // `proc_listallpids(nil, 0)` is not a reliable sizing probe on every
        // supported Darwin release. Keep an explicitly bounded inventory.
        var pids = [pid_t](repeating: 0, count: 16_384)
        let listed = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard listed > 0 else { return [] }
        return pids.prefix(Int(listed)).compactMap { pid in
            getpgid(pid) == processGroupID ? Int32(pid) : nil
        }
    }

    static func processGroup(of pid: Int32) -> Int32? {
        let group = getpgid(pid)
        return group < 0 ? nil : group
    }
}

public struct FoundationProcessRunner: ProcessRunner {
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

    public func start(_ request: ProcessRequest) throws -> any ProcessHandle {
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

private final class FoundationProcessHandle: ProcessHandle, @unchecked Sendable {
    private let pid: pid_t
    private let group: OwnedProcessGroup
    private let recorder: any OwnedProcessRecording
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let stdoutData = DataBox()
    private let stderrData = DataBox()
    private let readers = DispatchGroup()
    private let lifecycleLock = NSLock()
    private let recordingError = ErrorBox()
    private var monitor: DispatchSourceTimer?
    private var observed = Set<OwnedProcessIdentity>()
    private var finished = false
    private var cancellationRequested = false

    init(pid: pid_t, group: OwnedProcessGroup, recorder: any OwnedProcessRecording, stdout: FileHandle, stderr: FileHandle) {
        self.pid = pid
        self.group = group
        self.recorder = recorder
        self.stdout = stdout
        self.stderr = stderr
        observed.insert(group.leader)
        startReaders()
        startMonitor()
    }

    func wait() async throws -> ProcessResult {
        let status = await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) { self.waitForRoot() }.value
        }, onCancel: { self.cancel() })
        let cleaned = await waitForGroupAbsence()
        stopMonitor()
        await waitForReaders()
        if !cleaned || recordingError.hasError { throw ProcessCleanupError() }
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
        for pid in OwnedProcessGroupInspector.members(in: group.processGroupID) {
            guard let identity = ProcessIdentityReader.identity(for: pid) else { continue }
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

    private func waitForRoot() -> Int32 {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(pid, &status, 0)
            if result == pid { return decodedExitStatus(status) }
            if result == -1, errno != EINTR { return 1 }
        }
    }

    private func waitForGroupAbsence() async -> Bool {
        let termDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < termDeadline {
            recordStableGroupMembers()
            if groupIsAbsent() { return true }
            if recordingError.hasError { cancel() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        cancel()
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < killDeadline {
            signalVerifiedGroup(SIGKILL)
            if groupIsAbsent() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return groupIsAbsent()
    }

    private func groupIsAbsent() -> Bool { OwnedProcessGroupInspector.members(in: group.processGroupID).isEmpty }

    private func signalVerifiedGroup(_ signal: Int32) {
        if let leader = ProcessIdentityReader.identity(for: group.leader.pid), leader != group.leader {
            recordingError.retain(ProcessCleanupError())
            return
        }
        if ProcessIdentityReader.identity(for: group.leader.pid) == group.leader {
            // The live PGID leader still proves that this exact private group
            // belongs to us, so a group signal cannot target a reused PGID.
            let groupResult = Darwin.kill(-group.processGroupID, signal)
            // Keep the root reaping path live even on a Darwin configuration
            // that rejects a negative-PGID signal despite accepting the exact
            // same child PID.
            if ProcessIdentityReader.identity(for: group.leader.pid) == group.leader {
                if Darwin.kill(group.leader.pid, signal) != 0, groupResult != 0 {
                    recordingError.retain(ProcessCleanupError())
                }
            }
            return
        }
        for pid in OwnedProcessGroupInspector.members(in: group.processGroupID) {
            guard let identity = ProcessIdentityReader.identity(for: pid),
                  OwnedProcessGroupInspector.processGroup(of: pid) == group.processGroupID,
                  ProcessIdentityReader.identity(for: pid) == identity,
                  OwnedProcessGroupInspector.processGroup(of: pid) == group.processGroupID else { continue }
            _ = Darwin.kill(pid, signal)
        }
    }

    private func waitForReaders() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { self.readers.wait(); continuation.resume() }
        }
    }

    private static func readPipe(_ handle: FileHandle, maxBytes: Int = 4 * 1_024 * 1_024) -> Data {
        var result = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return result }
            if result.count < maxBytes { result.append(chunk.prefix(maxBytes - result.count)) }
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
