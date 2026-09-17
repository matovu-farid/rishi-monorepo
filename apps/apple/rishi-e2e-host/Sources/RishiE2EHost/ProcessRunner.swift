import Foundation

#if canImport(Darwin)
import Darwin
#endif

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

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    public func start(_ request: ProcessRequest) throws -> any ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        if !request.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        var hasPrivateProcessGroup = false
        #if canImport(Darwin)
        // Keep xcodebuild and the XCTest/app descendants in a private group
        // so cancellation cannot leave a simulator process behind.
        if process.isRunning {
            let result = setpgid(process.processIdentifier, process.processIdentifier)
            // Foundation.Process may race a short-lived child or report EPERM
            // after exec. Record ownership only when the group is confirmed;
            // cancellation falls back to terminating this owned process.
            hasPrivateProcessGroup = result == 0
        }
        #endif
        return FoundationProcessHandle(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, hasPrivateProcessGroup: hasPrivateProcessGroup)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}

struct ProcessCleanupError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "Owned XCTest process descendants could not be cleaned up."
    }
}

private final class FoundationProcessHandle: ProcessHandle, @unchecked Sendable {
    #if canImport(Darwin)
    // Process-tree discovery launches short-lived pgrep helpers. Keep all
    // discovery for every owned process serialized: overlapping Foundation
    // Process/waitpid calls can deadlock under Xcode Beta even though the
    // helper itself has already exited.
    private static let processDiscoveryLock = NSLock()
    #endif
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutData = DataBox()
    private let stderrData = DataBox()
    private let pipeReaders = DispatchGroup()
    private let hasPrivateProcessGroup: Bool
    private let lifecycleLock = NSLock()
    #if canImport(Darwin)
    private let ownershipLock = NSLock()
    private var ownedPIDs = Set<pid_t>()
    private var ownershipMonitor: DispatchSourceTimer?
    #endif
    private var finished = false
    private var cancellationRequested = false

    init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe, hasPrivateProcessGroup: Bool) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.hasPrivateProcessGroup = hasPrivateProcessGroup
        #if canImport(Darwin)
        // setpgid runs after Process.run(). Track the tree even when a private
        // group is established so children spawned in that small window and
        // left in the old group remain owned and cancellable.
        startOwnershipMonitor()
        recordOwnedProcessTree()
        #endif
        // Drain both pipes from process start, including for long-lived peer
        // xcodebuild processes. Retain only the existing bounded diagnostic
        // buffers so a build cannot stall on pipe backpressure or grow memory
        // without limit while the host waits for upload/rendezvous state.
        pipeReaders.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.pipeReaders.leave() }
            self.stdoutData.set(Self.readPipe(stdoutPipe.fileHandleForReading))
        }
        pipeReaders.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.pipeReaders.leave() }
            self.stderrData.set(Self.readPipe(stderrPipe.fileHandleForReading))
        }
    }

    func wait() async throws -> ProcessResult {
        // Reap the xcodebuild root first, but do not wait for the output
        // buffers yet. XCTest descendants can inherit these pipe descriptors;
        // waiting for EOF before the descendant cleanup below would deadlock
        // the host exactly when it most needs to reclaim resources.
        let exitStatus = await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) { self.blockingWait() }.value
        }, onCancel: {
            self.cancel()
        })
        guard await waitForExitAndCleanup() else {
            throw ProcessCleanupError()
        }
        await waitForPipeReaders()
        return ProcessResult(
            exitStatus: exitStatus,
            stdout: String(decoding: stdoutData.get(), as: UTF8.self),
            stderr: String(decoding: stderrData.get(), as: UTF8.self)
        )
    }

    /// Wait until the root and every process this runner observed have exited.
    /// XCTest can leave children behind after its xcodebuild root exits, so a
    /// root-only wait is not sufficient to release simulator, pipe, or build
    /// database resources.
    @discardableResult
    func waitForExitAndCleanup(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !ownedProcessesAreAlive() {
                markFinished()
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // If the root exited but a descendant remains, take ownership of the
        // remaining tree before force-killing it. This path is also used after
        // normal test completion, not only explicit cancellation.
        requestCancellationIfNeeded()
        forceKillOwnedProcesses()

        let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < forcedDeadline {
            if !ownedProcessesAreAlive() { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let cleaned = !ownedProcessesAreAlive()
        if cleaned { markFinished() }
        return cleaned
    }

    private func requestCancellationIfNeeded() {
        lifecycleLock.lock()
        let alreadyRequested = cancellationRequested
        lifecycleLock.unlock()
        if !alreadyRequested { cancel() }
    }

    private func forceKillOwnedProcesses() {
        lifecycleLock.lock()
        let processGroup = process.processIdentifier
        let privateGroup = hasPrivateProcessGroup
        lifecycleLock.unlock()
        #if canImport(Darwin)
        if privateGroup {
            _ = kill(-processGroup, SIGKILL)
            terminateOwnedProcessTree(signal: SIGKILL)
        } else {
            var remaining = ownedPIDsSnapshot()
            if process.isRunning {
                remaining.formUnion(Self.processTree(root: processGroup))
            }
            for pid in Array(remaining) {
                remaining.formUnion(Self.processTree(root: pid))
            }
            rememberOwned(remaining)
            for pid in remaining { _ = kill(pid, SIGKILL) }
        }
        #else
        if process.isRunning { process.terminate() }
        #endif
    }

    private func markFinished() {
        lifecycleLock.lock()
        finished = true
        lifecycleLock.unlock()
        #if canImport(Darwin)
        stopOwnershipMonitor()
        #endif
    }

    func cancel() {
        lifecycleLock.lock()
        guard !finished, !cancellationRequested else {
            lifecycleLock.unlock()
            return
        }
        cancellationRequested = true
        lifecycleLock.unlock()
        #if canImport(Darwin)
        if hasPrivateProcessGroup {
            // The root can exit while a descendant still owns one of these
            // pipes. The private group remains the safest ownership boundary;
            // do not gate this on Process.isRunning or getpgid(root), because
            // either can become false before the descendants are gone.
            let processGroup = process.processIdentifier
            _ = kill(-processGroup, SIGTERM)
            terminateOwnedProcessTree(signal: SIGTERM)
        } else {
            // A post-launch setpgid failure means the group is not ours. Walk
            // only this process's descendants instead of signalling an
            // unrelated shared process group, while retaining the ownership
            // snapshot for descendants re-parented after root exit.
            let rootPID = process.processIdentifier
            let initialPIDs = Self.processTree(root: rootPID)
            rememberOwned(initialPIDs)
            for pid in initialPIDs { _ = kill(pid, SIGTERM) }
        }
        #endif
        if process.isRunning { process.terminate() }
    }

    private var isFinished: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return finished
    }

    #if canImport(Darwin)
    private func startOwnershipMonitor() {
        let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Process-tree discovery shells out to pgrep. A half-second cadence
        // bounds monitor overhead without leaving a long-lived XCTest child
        // unobserved for a meaningful interval.
        monitor.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        monitor.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            self.rememberOwned(Self.processTree(root: self.process.processIdentifier))
        }
        ownershipMonitor = monitor
        monitor.resume()
    }

    private func stopOwnershipMonitor() {
        ownershipLock.lock()
        let monitor = ownershipMonitor
        ownershipMonitor = nil
        ownershipLock.unlock()
        monitor?.cancel()
    }

    private func recordOwnedProcessTree() {
        guard !isFinished else { return }
        rememberOwned(Self.processTree(root: process.processIdentifier))
    }

    private func rememberOwned<S: Sequence>(_ pids: S) where S.Element == pid_t {
        ownershipLock.lock()
        ownedPIDs.formUnion(pids)
        ownershipLock.unlock()
    }

    private func ownedPIDsSnapshot() -> Set<pid_t> {
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        return ownedPIDs
    }

    private func ownedProcessesAreAlive() -> Bool {
        var owned = ownedPIDsSnapshot()
        if process.isRunning {
            owned.formUnion(Self.processTree(root: process.processIdentifier))
        }
        if hasPrivateProcessGroup {
            // A process group can continue to exist while its members are
            // zombies. `kill(-pgid, 0)` reports that state as alive, which
            // made a completed Xcode build look like a hung process under
            // Xcode Beta. Enumerate the group and inspect member state
            // instead.
            owned.formUnion(Self.processGroup(root: process.processIdentifier))
        }
        rememberOwned(owned)
        return owned.contains { Self.isLiveProcess($0) }
    }

    private static func isLiveProcess(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/bin/ps")
        lookup.arguments = ["-o", "stat=", "-p", String(pid)]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = Pipe()
        do {
            try lookup.run()
            waitForShortProcess(lookup)
        } catch {
            return true
        }
        let state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !state.isEmpty && !state.hasPrefix("Z")
    }

    private static func processGroup(root: pid_t) -> [pid_t] {
        processDiscoveryLock.lock()
        defer { processDiscoveryLock.unlock() }
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        lookup.arguments = ["-g", String(root)]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = Pipe()
        do {
            try lookup.run()
            waitForShortProcess(lookup)
        } catch {
            return []
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }

    private static func processTree(root: pid_t) -> [pid_t] {
        processDiscoveryLock.lock()
        defer { processDiscoveryLock.unlock() }
        var pending = [root]
        var seen = Set<pid_t>()
        while let parent = pending.popLast() {
            guard seen.insert(parent).inserted else { continue }
            pending.append(contentsOf: childProcesses(of: parent))
        }
        return Array(seen)
    }

    private static func childProcesses(of parent: pid_t) -> [pid_t] {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        lookup.arguments = ["-P", String(parent)]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = Pipe()
        do {
            try lookup.run()
            waitForShortProcess(lookup)
        } catch {
            return []
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    private static func waitForShortProcess(_ process: Process) {
        #if canImport(Darwin)
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(process.processIdentifier, &status, 0)
            if result == process.processIdentifier || result == -1 && errno != EINTR { return }
        }
        #else
        process.waitUntilExit()
        #endif
    }

    private func terminateOwnedProcessTree(signal: Int32) {
        var owned = ownedPIDsSnapshot()
        if process.isRunning {
            owned.formUnion(Self.processTree(root: process.processIdentifier))
        }
        for pid in Array(owned) {
            owned.formUnion(Self.processTree(root: pid))
        }
        rememberOwned(owned)
        for pid in owned { _ = kill(pid, signal) }
    }
    #endif

    private func blockingWait() -> Int32 {
        // Xcode Beta can leave Foundation.Process.waitUntilExit() and
        // Process.isRunning stale after xcodebuild has disappeared from the
        // process table. Reap the owned child directly so a completed build
        // cannot be mistaken for a timed-out build.
        #if canImport(Darwin)
        var status: Int32 = 0
        let pid = process.processIdentifier
        while true {
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid {
                // The Darwin wait-status macros are unavailable to Swift in
                // the Xcode Beta SDK, so decode the POSIX status directly.
                let signal = status & 0x7f
                if signal == 0 { return (status >> 8) & 0xff }
                if signal != 0x7f { return 128 + signal }
                return process.terminationStatus
            }
            if result == -1 {
                if errno == EINTR { continue }
                // Foundation may have reaped the child first. In that case
                // its termination status is the only remaining source. Do
                // not consult Process.isRunning here: Xcode Beta can leave
                // that property stale after the child has disappeared.
                return process.terminationStatus
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #else
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return process.terminationStatus
        #endif
    }

    private func waitForPipeReaders() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.pipeReaders.wait()
                continuation.resume()
            }
        }
    }

    private static func readPipe(_ handle: FileHandle, maxBytes: Int = 4 * 1024 * 1024) -> Data {
        var result = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            guard result.count < maxBytes else { continue }
            result.append(chunk.prefix(maxBytes - result.count))
        }
        return result
    }

    #if canImport(Darwin)
    #endif
}
