import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public final class ManagedProcess: @unchecked Sendable {
    public let process: Process
    public let output: Pipe
    public let errors: Pipe
    private let hasPrivateProcessGroup: Bool
    private let lifecycleLock = NSLock()
    private let pipeLock = NSLock()
    private var pipesClosed = false
    #if canImport(Darwin)
    private let ownershipLock = NSLock()
    private var ownedPIDs = Set<pid_t>()
    private var ownershipMonitor: DispatchSourceTimer?
    #endif
    private var finished = false
    private var cancellationRequested = false
    init(process: Process, output: Pipe, errors: Pipe, hasPrivateProcessGroup: Bool, drainOutput: Bool) {
        self.process = process
        self.output = output
        self.errors = errors
        self.hasPrivateProcessGroup = hasPrivateProcessGroup
        if drainOutput {
            DispatchQueue.global(qos: .utility).async {
                Self.drainPipe(output.fileHandleForReading)
            }
            DispatchQueue.global(qos: .utility).async {
                Self.drainPipe(errors.fileHandleForReading)
            }
        }
        #if canImport(Darwin)
        // setpgid runs after Process.run(). Track the tree even when a private
        // group is established so children spawned in that small window and
        // left in the old group remain owned and cancellable.
        startOwnershipMonitor()
        recordOwnedProcessTree()
        #endif
    }
    public var isRunning: Bool { process.isRunning }
    public func stop() {
        killProcessGroup()
        if process.isRunning { process.terminate() }
    }
    public func killProcessGroup() {
        lifecycleLock.lock()
        guard !finished, !cancellationRequested else {
            lifecycleLock.unlock()
            return
        }
        cancellationRequested = true
        lifecycleLock.unlock()
        #if canImport(Darwin)
        if hasPrivateProcessGroup {
            let processGroup = process.processIdentifier
            // The root may already have exited while a descendant still owns
            // the output pipe. Signal the private group by its known group
            // leader rather than skipping cleanup because the root is gone.
            _ = Darwin.kill(-processGroup, SIGTERM)
            terminateOwnedProcessTree(signal: SIGTERM)
        } else {
            // setpgid can fail after Foundation has launched a short-lived
            // child. Do not signal an unowned group; record and terminate the
            // owned process tree. The bounded cleanup wait below performs the
            // force-kill after the final descendant sweep.
            let rootPID = process.processIdentifier
            let initialPIDs = Self.processTree(root: rootPID)
            rememberOwned(initialPIDs)
            for pid in initialPIDs { _ = Darwin.kill(pid, SIGTERM) }
        }
        #else
        if process.isRunning { process.terminate() }
        #endif
    }

    /// Close the read ends after process-tree cleanup. A descendant that was
    /// not attached to the expected process group must not be able to keep a
    /// command runner blocked forever by inheriting an output descriptor.
    public func closePipes() {
        pipeLock.lock()
        guard !pipesClosed else {
            pipeLock.unlock()
            return
        }
        pipesClosed = true
        pipeLock.unlock()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    func markFinished() {
        lifecycleLock.lock()
        finished = true
        lifecycleLock.unlock()
        #if canImport(Darwin)
        stopOwnershipMonitor()
        #endif
    }

    /// Wait for the Xcode root for a bounded interval, then terminate any
    /// descendants in the process group/tree that this runner owns. The root
    /// can exit before XCTest or the app does, so waiting on the root alone is
    /// not sufficient to release memory, simulator, or pipe resources.
    @discardableResult
    public func waitForExitAndCleanup(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !ownedProcessesAreAlive() {
                stopOwnershipMonitor()
                markFinished()
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Keep the caller's build/path locks held while force cleanup runs.
        // This avoids releasing a lock while an ignored XCTest descendant is
        // still using the derived-data database or output pipes.
        // A root that exited without an explicit cancellation can still leave
        // an owned XCTest/simulator descendant behind, so request cancellation
        // before the force-kill sweep instead of allowing that child to live
        // past the build lock.
        requestCancellationIfNeeded()
        forceKillOwnedProcesses()
        let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < forcedDeadline {
            if !ownedProcessesAreAlive() { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let cleaned = !ownedProcessesAreAlive()
        if cleaned {
            stopOwnershipMonitor()
            markFinished()
        }
        return cleaned
    }

    private func requestCancellationIfNeeded() {
        lifecycleLock.lock()
        let alreadyRequested = cancellationRequested
        lifecycleLock.unlock()
        if !alreadyRequested { killProcessGroup() }
    }

    private func forceKillOwnedProcesses() {
        lifecycleLock.lock()
        let ownsCancellation = cancellationRequested
        let processGroup = process.processIdentifier
        let privateGroup = hasPrivateProcessGroup
        lifecycleLock.unlock()
        guard ownsCancellation else { return }
        #if canImport(Darwin)
        if privateGroup {
            _ = Darwin.kill(-processGroup, SIGKILL)
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
            for pid in remaining {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        #else
        if process.isRunning { process.terminate() }
        #endif
    }

    private var isFinished: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return finished
    }

    private static func drainPipe(_ handle: FileHandle) {
        while !handle.availableData.isEmpty {}
    }

    #if canImport(Darwin)
    private func startOwnershipMonitor() {
        let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Process-tree discovery shells out to pgrep. A half-second cadence
        // bounds monitor overhead without leaving a long-lived XCTest child
        // unobserved for a meaningful interval.
        monitor.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        monitor.setEventHandler { [weak self] in
            self?.recordOwnedProcessTree()
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
        if hasPrivateProcessGroup {
            let processGroup = process.processIdentifier
            if Darwin.kill(-processGroup, 0) == 0 || errno == EPERM { return true }
        }

        var owned = ownedPIDsSnapshot()
        if process.isRunning {
            owned.formUnion(Self.processTree(root: process.processIdentifier))
            rememberOwned(owned)
        }
        return owned.contains { pid in
            Darwin.kill(pid, 0) == 0 || errno == EPERM
        }
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
        for pid in owned { _ = Darwin.kill(pid, signal) }
    }
    #else
    private func ownedProcessesAreAlive() -> Bool { process.isRunning }
    private func stopOwnershipMonitor() {}
    #endif

    #if canImport(Darwin)
    private static func processTree(root: pid_t) -> [pid_t] {
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
            lookup.waitUntilExit()
        } catch {
            return []
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
    #endif
}

public struct ProcessRunner: Sendable {
    public init() {}

    public func start(_ executable: String, arguments: [String], environment: [String: String], drainOutput: Bool = true) throws -> ManagedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe(); let errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        var hasPrivateProcessGroup = false
        #if canImport(Darwin)
        if process.isRunning {
            let result = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
            // Foundation.Process may race a short-lived child or report EPERM
            // after exec. Record ownership only when the group is confirmed;
            // cancellation falls back to terminating this owned process.
            hasPrivateProcessGroup = result == 0
        }
        #endif
        return ManagedProcess(process: process, output: output, errors: errors, hasPrivateProcessGroup: hasPrivateProcessGroup, drainOutput: drainOutput)
    }

    public func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration = .seconds(10)) async throws -> CommandResult {
        // The run path reads both pipes into bounded buffers below; long-lived
        // sessions use the default discarding drains from start() instead.
        let managed = try start(executable, arguments: arguments, environment: environment, drainOutput: false)
        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                // Drain both pipes while xcodebuild is running. Waiting for
                // exit before reading can deadlock once a verbose build fills
                // either pipe's kernel buffer.
                let stdoutTask = Task.detached {
                    readPipe(managed.output.fileHandleForReading)
                }
                let stderrTask = Task.detached {
                    readPipe(managed.errors.fileHandleForReading)
                }
                managed.process.waitUntilExit()
                guard await managed.waitForExitAndCleanup() else {
                    managed.closePipes()
                    throw RegistryError(.driverUnavailable, "command cleanup did not finish: \(executable)")
                }
                managed.closePipes()
                let result = CommandResult(
                    status: managed.process.terminationStatus,
                    stdout: String(data: await stdoutTask.value, encoding: .utf8) ?? "",
                    stderr: String(data: await stderrTask.value, encoding: .utf8) ?? ""
                )
                return result
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                managed.killProcessGroup()
                let cleaned = await managed.waitForExitAndCleanup(timeout: .seconds(3))
                managed.closePipes()
                if !cleaned {
                    throw RegistryError(.driverUnavailable, "timed-out command cleanup did not finish: \(executable)")
                }
                throw RegistryError(.waitTimeout, "command timed out: \(executable)")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func readPipe(_ handle: FileHandle, maxBytes: Int = 4 * 1024 * 1024) -> Data {
        var result = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else { break }
            if result.count < maxBytes {
                result.append(chunk.prefix(maxBytes - result.count))
            }
        }
        return result
    }
}

public struct ExternalTargetStopVerifier: Sendable {
    public typealias TargetReader = @Sendable () async throws -> Set<String>
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let targetReader: TargetReader
    private let timeout: Duration
    private let pollInterval: Duration
    private let sleeper: Sleeper

    public init(
        timeout: Duration,
        pollInterval: Duration,
        targetReader: @escaping TargetReader,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.targetReader = targetReader
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.sleeper = sleeper
    }

    public func waitUntilStopped(_ target: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            guard !(try await targetReader()).contains(target) else {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else {
                    throw RegistryError(.waitTimeout, "external target did not stop before timeout: \(target)")
                }
                try await sleeper(min(pollInterval, remaining))
                continue
            }
            return
        }
    }
}

public enum XCTestStopCoordinator {
    public static func stop(
        target: String,
        requestStop: @escaping @Sendable () async throws -> Void,
        stopOwnedProcess: @escaping @Sendable () async -> Void,
        waitForOwnedProcessCleanup: @escaping @Sendable () async -> Bool,
        externalTargets: @escaping ExternalTargetStopVerifier.TargetReader,
        releaseOwnership: @escaping @Sendable () async throws -> Void,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(100),
        sleep: @escaping ExternalTargetStopVerifier.Sleeper = { try await Task.sleep(for: $0) }
    ) async throws {
        var stopRequestError: Error?
        do { try await requestStop() } catch { stopRequestError = error }
        await stopOwnedProcess()
        guard await waitForOwnedProcessCleanup() else {
            throw RegistryError(.driverUnavailable, "owned XCTest process cleanup did not finish; build lock retained")
        }
        if let stopRequestError { throw stopRequestError }
        try await ExternalTargetStopVerifier(
            timeout: timeout,
            pollInterval: pollInterval,
            targetReader: externalTargets,
            sleeper: sleep
        ).waitUntilStopped(target)
        try await releaseOwnership()
    }
}

public enum AppTarget: String, Sendable, CaseIterable { case catalyst, iphone17 }

public struct SimulatorDevice: Sendable, Equatable {
    public let name: String; public let udid: String; public let state: String
    public init(name: String, udid: String, state: String) { self.name = name; self.udid = udid; self.state = state }
}

private final class BridgeConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(_ fd: Int32) {
        self.fd = fd
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        #if canImport(Darwin)
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        #endif
    }
}

public actor XCTestDriver: AppleAppDriver {
    public struct Configuration: Sendable {
        public let projectPath: String
        public let scheme: String
        public let environment: [String: String]
        public let temporaryRoot: String
        private let runRoot: String
        public init(projectPath: String, scheme: String = "rishi-mcp", environment: [String: String] = ProcessInfo.processInfo.environment, temporaryRoot: String = NSTemporaryDirectory(), runID: String = UUID().uuidString) {
            self.projectPath = projectPath
            self.scheme = scheme
            self.environment = environment
            self.temporaryRoot = temporaryRoot
            self.runRoot = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
                .appendingPathComponent("rishi-mcp-\(runID)", isDirectory: true).path
        }
        public func derivedDataPath(for target: AppTarget) -> String {
            let targetKey = target == .catalyst ? "CATALYST" : "IPHONE17"
            if let explicit = environment["RISHI_MCP_DERIVED_DATA_\(targetKey)"], !explicit.isEmpty { return explicit }
            if let base = environment["RISHI_MCP_DERIVED_DATA"], !base.isEmpty {
                return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(target.rawValue, isDirectory: true).path
            }
            return URL(fileURLWithPath: runRoot, isDirectory: true)
                .appendingPathComponent("derived-\(target.rawValue)", isDirectory: true).path
        }
        public func ownsDerivedData(for target: AppTarget) -> Bool {
            let targetKey = target == .catalyst ? "CATALYST" : "IPHONE17"
            return (environment["RISHI_MCP_DERIVED_DATA_\(targetKey)"]?.isEmpty ?? true)
                && (environment["RISHI_MCP_DERIVED_DATA"]?.isEmpty ?? true)
        }
        public func sourcePackagesPath() -> String {
            if let explicit = environment["RISHI_MCP_SOURCE_PACKAGES"], !explicit.isEmpty {
                return explicit
            }
            return URL(fileURLWithPath: temporaryRoot, isDirectory: true)
                .appendingPathComponent("rishi-source-packages", isDirectory: true).path
        }
        public func xcodebuildArguments(for target: AppTarget, deviceID: String? = nil, resultBundlePath: String) -> [String] {
            let destination = target == .catalyst ? "platform=macOS,variant=Mac Catalyst" : "platform=iOS Simulator,id=\(deviceID ?? "")"
            let action = environment["RISHI_MCP_TEST_WITHOUT_BUILDING"] == "1" ? "test-without-building" : "test"
            return [action, "-project", projectPath, "-scheme", scheme, "-configuration", "Debug", "-destination", destination, "-only-testing:rishiUITests/MCPControlUITests/testServer", "-parallel-testing-enabled", "NO", "-derivedDataPath", derivedDataPath(for: target), "-clonedSourcePackagesDirPath", sourcePackagesPath(), "-resultBundlePath", resultBundlePath]
        }
    }

    private final class Session: @unchecked Sendable {
        let target: AppTarget; let temporaryDirectory: URL; let bridgeConfig: URL; let bridge: LocalBridgeServer; let process: ManagedProcess; let buildLock: BuildPathLock; let derivedDataPath: URL; let ownsDerivedData: Bool
        var output = ""; var externalLaunch: Bool = false
        var stopping = false
        var resourceWatchdog: Task<Void, Never>?
        var pending: [(UUID, JSONValue, CheckedContinuation<JSONValue, Error>)] = []
        var active: [UUID: (CheckedContinuation<JSONValue, Error>, BridgeConnection)] = [:]
        var timeoutTasks: [UUID: Task<Void, Never>] = [:]
        init(target: AppTarget, temporaryDirectory: URL, bridgeConfig: URL, bridge: LocalBridgeServer, process: ManagedProcess, buildLock: BuildPathLock, derivedDataPath: URL, ownsDerivedData: Bool) { self.target = target; self.temporaryDirectory = temporaryDirectory; self.bridgeConfig = bridgeConfig; self.bridge = bridge; self.process = process; self.buildLock = buildLock; self.derivedDataPath = derivedDataPath; self.ownsDerivedData = ownsDerivedData }
    }

    private let configuration: Configuration
    private let developerDirectory: String
    private let runner = ProcessRunner()
    private let externalTargetProvider: (@Sendable () async throws -> Set<String>)?
    private var sessions: [AppTarget: Session] = [:]
    private var ownedScreenshots: [AppTarget: [URL]] = [:]

    public init(configuration: Configuration = XCTestDriver.defaultConfiguration(), externalTargetProvider: (@Sendable () async throws -> Set<String>)? = nil) throws {
        self.configuration = configuration
        self.developerDirectory = try XcodeToolchain.resolveDeveloperDirectory(environment: configuration.environment)
        self.externalTargetProvider = externalTargetProvider
    }

    public static func defaultConfiguration() -> Configuration {
        let path = ProcessInfo.processInfo.environment["RISHI_MCP_PROJECT"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rishi/rishi.xcodeproj").path
        return Configuration(projectPath: path)
    }

    public static func selectIPhone17DeviceIDs(_ devices: [SimulatorDevice]) -> [String] {
        devices.filter { $0.name == "iPhone 17 Pro" }.sorted { ($0.state == "Booted" ? 1 : 0) > ($1.state == "Booted" ? 1 : 0) }.map(\.udid)
    }

    public static func screenshotArguments(for target: AppTarget, deviceID: String?, path: String) throws -> [String] {
        if target == .iphone17 {
            guard let deviceID, !deviceID.isEmpty else { throw RegistryError(.driverUnavailable, "no available iPhone 17 Pro simulator for screenshot capture") }
            return ["xcrun", "simctl", "io", deviceID, "screenshot", path]
        }
        return ["screencapture", "-x", "-o", path]
    }

    public func listApps() async throws -> [AppInstance] {
        await reapExitedSessions()
        var targets = Set(sessions.keys.map(\.rawValue))
        targets.formUnion(try await observedExternalTargets())
        return targets.sorted().map { AppInstance(id: $0, displayName: "Rishi \($0)", isRunning: true, windowCount: 1) }
    }

    public func launch(_ targetName: String) async throws {
        guard let target = AppTarget(rawValue: targetName) else { throw RegistryError(.actionNotSupported, "unsupported app target: \(targetName)") }
        guard sessions[target] == nil else { throw RegistryError(.instanceAlreadyRunning, "target already running: \(targetName)") }
        guard !(try await observedExternalTargets()).contains(targetName) else { throw RegistryError(.instanceAlreadyRunning, "target already running: \(targetName)", data: ["app": .string(targetName)]) }
        let deviceID = target == .iphone17 ? try await iPhone17DeviceIDs().first : nil
        if target == .iphone17 && deviceID == nil { throw RegistryError(.driverUnavailable, "no available iPhone 17 Pro simulator for external launch") }
        let derivedDataPath = configuration.derivedDataPath(for: target)
        do {
            try ResourcePreflight.requireSufficient(for: URL(fileURLWithPath: derivedDataPath), environment: configuration.environment)
        } catch let error as ResourcePreflightError {
            throw RegistryError(.driverUnavailable, error.localizedDescription)
        }
        if configuration.environment["RISHI_MCP_TEST_WITHOUT_BUILDING"] == "1",
           !FileManager.default.fileExists(atPath: derivedDataPath) {
            throw RegistryError(.driverUnavailable, "test-without-building requires existing derived data: \(derivedDataPath)")
        }
        let buildLock = try BuildPathLock.acquire(derivedDataPath: derivedDataPath, target: target)
        let sharedBuildLock = try SharedBuildLock.acquire(environment: configuration.environment)
        var sharedBuildLockReleased = false
        var sessionInstalled = false
        var temp: URL?
        var bridge: LocalBridgeServer?
        defer {
            if !sharedBuildLockReleased { try? sharedBuildLock.release() }
            if !sessionInstalled {
                bridge?.stop()
                if let temp { try? FileManager.default.removeItem(at: temp) }
                try? buildLock.release()
                if configuration.ownsDerivedData(for: target) {
                    try? FileManager.default.removeItem(atPath: derivedDataPath)
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: derivedDataPath).deletingLastPathComponent())
                }
            }
        }
        try await preflightBuild(target: target, deviceID: deviceID, derivedDataPath: derivedDataPath)
        let temporaryDirectory = URL(fileURLWithPath: configuration.temporaryRoot).appendingPathComponent("rishi-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        temp = temporaryDirectory
        let localBridge = try LocalBridgeServer()
        try localBridge.start()
        bridge = localBridge
        let bridgeConfig = temporaryDirectory.appendingPathComponent("bridge.json")
        try writeBridgeConfig(bridgeConfig, port: localBridge.port)
        var env = configuration.environment
        env["DEVELOPER_DIR"] = developerDirectory
        env["RISHI_MCP_BRIDGE_CONFIG"] = bridgeConfig.path
        let resultBundle = temporaryDirectory.appendingPathComponent("\(target.rawValue).xcresult").path
        let executable = "\(developerDirectory)/usr/bin/xcodebuild"
        let process = try runner.start(executable, arguments: configuration.xcodebuildArguments(for: target, deviceID: deviceID, resultBundlePath: resultBundle), environment: env)
        let session = Session(target: target, temporaryDirectory: temporaryDirectory, bridgeConfig: bridgeConfig, bridge: localBridge, process: process, buildLock: buildLock, derivedDataPath: URL(fileURLWithPath: derivedDataPath, isDirectory: true), ownsDerivedData: configuration.ownsDerivedData(for: target))
        sessions[target] = session
        sessionInstalled = true
        localBridge.onConnection = { [weak self, weak session] connection in
            guard let self, let session else { close(connection) ; return }
            Task { await self.handleConnection(connection, session: session) }
        }
        process.process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            Task { await self.reapExitedSession(target: target, process: process) }
        }
        startResourceWatchdog(for: session, target: target, derivedDataPath: derivedDataPath)
        if !process.isRunning {
            await reapExitedSession(target: target, process: process)
        }
        do { _ = try await request(target.rawValue, payload: .object(["op": .string("ping")]), timeoutMs: 120_000) }
        catch { try? await terminate(targetName); throw error }
        // The xcodebuild test process may still be compiling and launching
        // the test runner after Process.run() returns. Keep the cross-process
        // lock until the bridge handshake proves that the build/test process
        // has reached the running XCTest phase; otherwise two MCP launches
        // can still perform concurrent Xcode builds despite separate derived
        // data directories.
        try sharedBuildLock.release()
        sharedBuildLockReleased = true
    }

    public func terminate(_ targetName: String) async throws {
        guard let target = AppTarget(rawValue: targetName), let session = sessions[target] else { return }
        session.stopping = true
        session.resourceWatchdog?.cancel()
        session.resourceWatchdog = nil
        for active in session.active.values {
            active.1.close()
            active.0.resume(throwing: RegistryError(.instanceNotFound, "bridge stopped for \(targetName)"))
        }
        session.active.removeAll()
        try await XCTestStopCoordinator.stop(
            target: targetName,
            requestStop: { [weak self] in
                guard let self else { throw RegistryError(.driverUnavailable, "driver released while stopping \(targetName)") }
                _ = try await self.request(targetName, payload: .object(["op": .string("stop")]), timeoutMs: 2_000)
            },
            stopOwnedProcess: { session.process.stop() },
            waitForOwnedProcessCleanup: { await session.process.waitForExitAndCleanup() },
            externalTargets: { [weak self] in
                guard let self else { throw RegistryError(.driverUnavailable, "driver released while stopping \(targetName)") }
                return try await self.observedExternalTargets()
            },
            releaseOwnership: { [weak self] in
                guard let self else { return }
                await self.releaseSession(session, target: target)
            }
        )
    }

    private func reapExitedSessions() async {
        for (target, session) in sessions where !session.process.isRunning && !session.stopping {
            try? await terminate(target.rawValue)
        }
    }

    private func reapExitedSession(target: AppTarget, process: ManagedProcess) async {
        guard let session = sessions[target],
              session.process === process,
              !session.stopping,
              !process.isRunning else {
            return
        }
        try? await terminate(target.rawValue)
    }

    public func state(_ target: String, screenshot: Bool) async throws -> JSONValue {
        let result = try await request(target, payload: .object(["op": .string("snapshot")]), timeoutMs: 30_000)
        var screenshots: [JSONValue] = []
        if screenshot { screenshots = [.object(["id": .string("latest"), "url": .string(try await captureScreenshot(target))])] }
        return .object(["window": .object(["id": .integer(1), "app": .string(target)]), "accessibility": .object(["tree": result["debugDescription"] ?? .string("")]), "screenshots": .array(screenshots)])
    }

    public func logs(_ target: String, limit: Int) async throws -> JSONValue {
        let directory: String
        if target == AppTarget.catalyst.rawValue { directory = NSHomeDirectory() + "/Library/Containers/org.fidexa.rishi/Data/Library/Application Support/rishi-dump" }
        else { directory = ((try? await run("xcrun", ["simctl", "get_app_container", try await iPhone17DeviceIDs().first ?? "", "org.fidexa.rishi", "data"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") + "/tmp/rishi-dump" }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("all.log")
        let raw = Self.readLogTail(from: url)
        let boundedLimit = max(0, min(limit, 2_000))
        let entries = raw.split(separator: "\n").suffix(boundedLimit).compactMap { try? JSONValue(data: Data($0.utf8)) }
        return .object(["target": .string(target), "directory": .string(directory), "entries": .array(entries)])
    }

    private static func readLogTail(from url: URL, maxBytes: Int = 1_048_576) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return "" }
        do {
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    public func request(_ target: String, payload: JSONValue, timeoutMs: Int = 30_000) async throws -> JSONValue {
        guard let app = AppTarget(rawValue: target), let session = sessions[app] else { throw RegistryError(.instanceNotFound, "no XCTest session for \(target)") }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                session.pending.append((id, payload, continuation))
                session.timeoutTasks[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(timeoutMs)) }
                    catch { return }
                    await self?.expire(id: id, target: app)
                }
            }
        }, onCancel: { Task { await self.cancel(id: id, target: app) } })
    }

    public func clickIdentifier(_ target: String, identifier: String, action: String) async throws -> JSONValue { try await request(target, payload: .object(["op": .string("tap"), "identifier": .string(identifier), "action": .string(action)])) }
    public func clickText(_ target: String, text: String) async throws -> JSONValue { try await request(target, payload: .object(["op": .string("tapText"), "text": .string(text)])) }
    public func openURL(_ target: String, url: String) async throws -> JSONValue { try await request(target, payload: .object(["op": .string("openURL"), "url": .string(url)])) }

    private func run(_ command: String, _ arguments: [String], timeout: Duration = .seconds(30)) async throws -> CommandResult {
        try await runner.run(
            "/usr/bin/env",
            arguments: [command] + arguments,
            environment: ["DEVELOPER_DIR": developerDirectory],
            timeout: timeout
        )
    }

    private func preflightBuild(target: AppTarget, deviceID: String?, derivedDataPath: String) async throws {
        let version = try await run("xcodebuild", ["-version"])
        guard version.status == 0, version.stdout.contains("Xcode") else {
            throw RegistryError(.driverUnavailable, "Xcode preflight failed: \(version.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if target == .iphone17 && deviceID == nil {
            throw RegistryError(.driverUnavailable, "no available iPhone 17 Pro simulator for build preflight")
        }
        guard configuration.environment["RISHI_MCP_TEST_WITHOUT_BUILDING"] != "1" else { return }
        let destination = target == .catalyst
            ? "platform=macOS,variant=Mac Catalyst"
            : "platform=iOS Simulator,id=\(deviceID ?? "")"
        let arguments = [
            "xcodebuild", "-resolvePackageDependencies",
            "-project", configuration.projectPath,
            "-scheme", configuration.scheme,
            "-configuration", "Debug",
            "-destination", destination,
            "-derivedDataPath", derivedDataPath,
            "-clonedSourcePackagesDirPath", configuration.sourcePackagesPath()
        ]
        let result = try await run("xcodebuild", Array(arguments.dropFirst()), timeout: .seconds(180))
        guard result.status == 0 else {
            throw RegistryError(.driverUnavailable, "Swift Package resolution failed: \(result.stderr.suffix(2_000))")
        }
        do {
            try ResourcePreflight.requireSufficient(
                for: URL(fileURLWithPath: derivedDataPath),
                environment: configuration.environment
            )
        } catch let error as ResourcePreflightError {
            throw RegistryError(.driverUnavailable, error.localizedDescription)
        }
    }

    private func startResourceWatchdog(for session: Session, target: AppTarget, derivedDataPath: String) {
        session.resourceWatchdog?.cancel()
        let environment = configuration.environment
        session.resourceWatchdog = Task { [weak self, weak session] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self, let session, !session.stopping else { return }
                do {
                    try ResourcePreflight.requireSufficient(
                        for: URL(fileURLWithPath: derivedDataPath),
                        environment: environment
                    )
                } catch {
                    await self.stopForResourcePressure(
                        target: target,
                        message: error.localizedDescription
                    )
                    return
                }
            }
        }
    }

    private func stopForResourcePressure(target: AppTarget, message: String) async {
        guard let session = sessions[target], !session.stopping else { return }
        FileHandle.standardError.write(
            Data("rishi-apple-mcp: stopping \(target.rawValue) to protect system resources: \(message)\n".utf8)
        )
        do {
            try await terminate(target.rawValue)
        } catch {
            FileHandle.standardError.write(
                Data("rishi-apple-mcp: resource-pressure cleanup failed for \(target.rawValue): \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private func iPhone17DeviceIDs() async throws -> [String] {
        let result = try await run("xcrun", ["simctl", "list", "devices", "available", "-j"])
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail.prefix(500))"
            throw RegistryError(.driverUnavailable, "CoreSimulatorService is unavailable\(suffix)")
        }
        guard let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else {
            throw RegistryError(.driverUnavailable, "simctl returned invalid simulator-device data")
        }
        let matching = Self.selectIPhone17DeviceIDs(devices.values.flatMap { $0 }.compactMap { value in guard let name = value["name"] as? String, let udid = value["udid"] as? String, let state = value["state"] as? String else { return nil }; return SimulatorDevice(name: name, udid: udid, state: state) })
        if let explicit = configuration.environment["RISHI_MCP_IPHONE_DEVICE"], !explicit.isEmpty {
            return matching.filter { $0 == explicit }
        }
        return matching
    }
    private func observedExternalTargets() async throws -> Set<String> {
        if let externalTargetProvider { return try await externalTargetProvider() }
        return try await externalTargets()
    }

    private func externalTargets() async throws -> Set<String> {
        let ps = try await run("ps", ["-axo", "pid=,command="]).stdout
        let deviceIDs = try await iPhone17DeviceIDs().map { $0.lowercased() }
        var result = Set<String>()
        for line in ps.split(separator: "\n") {
            let value = String(line)
            if value.range(of: #"rishi\.app/Contents/MacOS/rishi(?:\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil { result.insert("catalyst") }
            if deviceIDs.contains(where: { value.lowercased().contains("/devices/\($0)/") }) && value.range(of: #"rishi\.app/rishi(?:\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil { result.insert("iphone17") }
        }
        return result
    }

    private func releaseSession(_ session: Session, target: AppTarget) {
        session.bridge.stop(); sessions.removeValue(forKey: target)
        for task in session.timeoutTasks.values { task.cancel() }
        session.timeoutTasks.removeAll()
        for (_, _, continuation) in session.pending { continuation.resume(throwing: RegistryError(.instanceNotFound, "bridge stopped for \(target.rawValue)")) }
        session.pending.removeAll()
        try? FileManager.default.removeItem(at: session.bridgeConfig)
        try? FileManager.default.removeItem(at: session.temporaryDirectory)
        try? session.buildLock.release()
        if session.ownsDerivedData {
            try? FileManager.default.removeItem(at: session.derivedDataPath)
            try? FileManager.default.removeItem(at: session.derivedDataPath.deletingLastPathComponent())
        }
        for screenshot in ownedScreenshots.removeValue(forKey: target) ?? [] {
            try? FileManager.default.removeItem(at: screenshot)
        }
    }
    private func expire(id: UUID, target: AppTarget) {
        guard let session = sessions[target] else { return }
        session.timeoutTasks.removeValue(forKey: id)?.cancel()
        if let index = session.pending.firstIndex(where: { $0.0 == id }) {
            let pending = session.pending.remove(at: index)
            pending.2.resume(throwing: RegistryError(.waitTimeout, "bridge timeout"))
        } else if let active = session.active.removeValue(forKey: id) {
            active.1.close()
            active.0.resume(throwing: RegistryError(.waitTimeout, "bridge timeout"))
        }
    }
    private func cancel(id: UUID, target: AppTarget) {
        guard let session = sessions[target] else { return }
        session.timeoutTasks.removeValue(forKey: id)?.cancel()
        if let index = session.pending.firstIndex(where: { $0.0 == id }) {
            let pending = session.pending.remove(at: index)
            pending.2.resume(throwing: CancellationError())
        } else if let active = session.active.removeValue(forKey: id) {
            active.1.close()
            active.0.resume(throwing: CancellationError())
        }
    }
    private func handleConnection(_ connection: Int32, session: Session) async {
        let tracked = BridgeConnection(connection)
        guard let index = session.pending.indices.first else { tracked.close(); return }
        let pending = session.pending.remove(at: index)
        session.active[pending.0] = (pending.2, tracked)
        do {
            if !session.externalLaunch {
                try await launchExternalTarget(session); session.externalLaunch = true
            }
            try BridgeCodec.write(pending.1, to: tracked.fd)
            let response = try await Task.detached(priority: .utility) {
                try BridgeCodec.readResponse(from: tracked.fd)
            }.value
            if response["ok"]?.boolValue == false { throw RegistryError(.stateChanged, response["error"]?.stringValue ?? "bridge action failed") }
            if let active = session.active.removeValue(forKey: pending.0) {
                session.timeoutTasks.removeValue(forKey: pending.0)?.cancel()
                active.0.resume(returning: response)
            }
        } catch {
            if let active = session.active.removeValue(forKey: pending.0) {
                session.timeoutTasks.removeValue(forKey: pending.0)?.cancel()
                active.0.resume(throwing: error)
            }
        }
        tracked.close()
    }
    private func launchExternalTarget(_ session: Session) async throws {
        if session.target == .catalyst {
            let path = configuration.derivedDataPath(for: .catalyst) + "/Build/Products/Debug-maccatalyst/rishi.app"
            let result = try await run("open", [path]); guard result.status == 0 else { throw RegistryError(.driverUnavailable, "could not launch Catalyst app externally: \(result.stderr)") }
        } else {
            guard let device = try await iPhone17DeviceIDs().first else { throw RegistryError(.driverUnavailable, "no available iPhone 17 Pro simulator for external launch") }
            let result = try await run("xcrun", ["simctl", "launch", device, "org.fidexa.rishi"]); guard result.status == 0 else { throw RegistryError(.driverUnavailable, "could not launch iPhone 17 Pro app externally: \(result.stderr)") }
        }
    }
    private func captureScreenshot(_ target: String) async throws -> String {
        let path = "/private/tmp/rishi-mcp-\(target)-screenshot-\(UUID().uuidString).png"
        guard let appTarget = AppTarget(rawValue: target) else { throw RegistryError(.actionNotSupported, "unsupported app target: \(target)") }
        let deviceID = appTarget == .iphone17 ? try await iPhone17DeviceIDs().first : nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = try Self.screenshotArguments(for: appTarget, deviceID: deviceID, path: path)
        process.environment = ["DEVELOPER_DIR": developerDirectory]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: path)
            throw RegistryError(.stateChanged, "could not capture \(target) screenshot")
        }

        let screenshotURL = URL(fileURLWithPath: path)
        var screenshots = ownedScreenshots[appTarget, default: []]
        screenshots.append(screenshotURL)
        // Keep the newest bounded set available to MCP callers while
        // preventing repeated captures from filling the data volume.
        while screenshots.count > 20 {
            let expired = screenshots.removeFirst()
            try? FileManager.default.removeItem(at: expired)
        }
        ownedScreenshots[appTarget] = screenshots
        return screenshotURL.absoluteString
    }
    private func writeBridgeConfig(_ url: URL, port: UInt16) throws { let data = try JSONSerialization.data(withJSONObject: ["port": port, "launchApp": false]); try data.write(to: url, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
}

public final class LocalBridgeServer: @unchecked Sendable {
    private var socket: Int32 = -1
    private let lock = NSLock()
    public var onConnection: (@Sendable (Int32) -> Void)?
    public private(set) var port: UInt16 = 0
    public init() throws {}
    public func start() throws {
        #if canImport(Darwin)
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); guard socket >= 0 else { throw RegistryError(.driverUnavailable, "could not create MCP bridge socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }; guard bound == 0 else { stop(); throw RegistryError(.driverUnavailable, "could not bind MCP bridge socket") }
        guard Darwin.listen(socket, 8) == 0 else { stop(); throw RegistryError(.driverUnavailable, "could not listen on MCP bridge socket") }
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size); getsockname(socket, withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &length); port = UInt16(bigEndian: actual.sin_port)
        let fd = socket; DispatchQueue.global(qos: .utility).async { [weak self] in while true { let connection = Darwin.accept(fd, nil, nil); if connection < 0 { return }; self?.onConnection?(connection) } }
        #else
        throw RegistryError(.driverUnavailable, "MCP bridge sockets require Darwin")
        #endif
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if socket >= 0 {
            #if canImport(Darwin)
            Darwin.close(socket)
            #endif
            socket = -1
        }
    }
}

public enum BridgeCodec {
    public static func request(from data: Data) throws -> [String: JSONValue] {
        guard data.count <= 1_048_576, let newline = data.firstIndex(of: 10) else { throw RegistryError(.stateChanged, "MCP bridge request exceeded 1 MiB or was not newline-terminated") }
        guard case .object(let value) = try JSONValue(data: data.prefix(upTo: newline)) else { throw RegistryError(.stateChanged, "MCP bridge request must be a JSON object") }; return value
    }
    public static func write(_ value: JSONValue, to fd: Int32) throws {
        var data = try value.data; data.append(10)
        #if canImport(Darwin)
        try data.withUnsafeBytes { buffer in var offset = 0; while offset < buffer.count { let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset); guard count > 0 else { throw RegistryError(.stateChanged, "could not write MCP bridge request") }; offset += count } }
        #else
        throw RegistryError(.driverUnavailable, "MCP bridge sockets require Darwin")
        #endif
    }
    public static func readResponse(from fd: Int32) throws -> JSONValue {
        #if canImport(Darwin)
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096); while true { let count = Darwin.read(fd, &bytes, bytes.count); guard count > 0 else { throw RegistryError(.stateChanged, "MCP bridge connection closed before responding") }; data.append(bytes, count: count); guard data.count <= 2_097_152 else { throw RegistryError(.stateChanged, "bridge response exceeded 2 MiB") }; if data.contains(10) { break } }; let value = try JSONValue(data: data.prefix { $0 != 10 }); guard case .object = value else { throw RegistryError(.stateChanged, "MCP bridge response must be a JSON object") }; return value
        #else
        throw RegistryError(.driverUnavailable, "MCP bridge sockets require Darwin")
        #endif
    }
}
